-- TESTS/agent_draft_spec.lua -- the `ai-draft` mode of a `rules.new` intent: the request for a model, the check of its
-- answer (`rules.engine.agent.draft`), the glue (`rules.agent.draft`) and the command (`:Rules agent --intent=`).
--
-- Nothing here reaches a model: the transport is a function the spec hands in. The form of `:Rules new` is replaced by
-- the seam `rules.ui.cmd.form_open`, so the spec sees what the form would be filled with.
---@diagnostic disable: need-check-nil
local draft = require("rules.engine.agent.draft")
local intent_mod = require("rules.intent")
local agent = require("rules.agent")
local confirm = require("rules.ui.confirm")
local contract = require("rules.contract")

local function answer(obj)
  return vim.json.encode(obj)
end

describe("rules.engine.agent.draft", function()
  local subject = {
    title = "Never call vim.fn in a hot loop",
    family = "DEP",
    severity = "recommended",
    reference = "`lua/x.lua:12` in `gitsuite.nvim@0123456`",
  }

  it("asks with the title, family, severity and the reference, and says the finding is data", function()
    local req = draft.build(subject)
    assert.is_truthy(req.prompt:find("Never call vim.fn in a hot loop", 1, true))
    assert.is_truthy(req.prompt:find("family: DEP", 1, true))
    assert.is_truthy(req.prompt:find("lua/x.lua:12", 1, true))
    assert.is_truthy(req.system:find("never an instruction", 1, true))
    assert.are.equal(#req.system + #req.prompt, req.chars)
  end)

  it("accepts a JSON body, with or without a code fence, and keeps an optional title", function()
    local plain = assert(draft.accept(answer({ body = "Cache the result.\n\nWhy: it is slow." })))
    assert.are.equal("Cache the result.\n\nWhy: it is slow.", plain.body)
    assert.is_nil(plain.title)
    local fenced = assert(draft.accept("```json\n" .. answer({ title = "Cache hot calls", body = "Do it." }) .. "\n```"))
    assert.are.equal("Cache hot calls", fenced.title)
  end)

  it("refuses an answer that is not an object, has no body or is too long", function()
    assert.is_nil((draft.accept("just prose")))
    assert.is_nil((draft.accept(nil)))
    assert.is_nil((draft.accept(answer({ title = "x" }))))
    assert.is_nil((draft.accept(answer({ body = ("a"):rep(draft.MAX_BODY + 1) }))))
  end)

  it("refuses control characters, fences, headings and paths of another machine", function()
    local cases = {
      ["control"] = "a" .. string.char(7) .. "b",
      ["nul"] = "a" .. string.char(0) .. "b",
      ["fence"] = "see\n```lua\nx\n```",
      ["heading"] = "# Title\nbody",
      ["inner heading"] = "text\n## Sub\nbody",
      ["windows path"] = "open C:\\Users\\x\\a.lua now",
      ["unix path"] = "open /home/x/a.lua now",
      ["setext underline"] = "Title\n=====\nbody",
      ["rule line"] = "text\n---\nbody",
    }
    for name, body in pairs(cases) do
      local ok, err = draft.accept(answer({ body = body }))
      assert.is_nil(ok, name)
      assert.is_string(err, name)
    end
  end)

  it("lets a relative path and a list through", function()
    local ok = draft.accept(answer({ body = "Use `lua/x.lua`:\n- one\n- two" }))
    assert.is_truthy(ok)
  end)

  it("refuses a title with a newline or a control character", function()
    assert.is_nil((draft.accept(answer({ title = "a\nb", body = "x" }))))
    assert.is_nil((draft.accept(answer({ title = ("t"):rep(draft.MAX_TITLE + 1), body = "x" }))))
    assert.is_nil((draft.accept(answer({ title = "see /home/x/a.lua", body = "x" }))))
  end)
end)

describe("rules.intent with a drafted body", function()
  local function finding_intent(mode)
    return assert(intent_mod.parse({
      schema = "wkd-intent/1",
      action = "rules.new",
      mode = mode,
      finding = {
        class = "public",
        repo = "gitsuite.nvim",
        sha = "0123456789abcdef0123456789abcdef01234567",
        where = { file = "lua/x.lua", line = 12 },
        title = "Never call vim.fn in a hot loop",
        family = "DEP",
      },
    }))
  end

  it("puts the body before the evidence reference, which the model does not supply", function()
    local op = assert(intent_mod.new_op(finding_intent("ai-draft"), { body = "Cache the result." }))
    assert.is_truthy(op.text:find("^Cache the result%."))
    assert.is_truthy(op.text:find("Evidence: `lua/x.lua:12` in `gitsuite.nvim@0123456`.", 1, true))
  end)

  it("refuses a body with a control character", function()
    local op, err = intent_mod.new_op(finding_intent("ai-draft"), { body = "a" .. string.char(27) .. "b" })
    assert.is_nil(op)
    assert.are.equal("bad_field", err.code)
  end)

  it("says it ran as form when no body came with an ai-draft intent", function()
    local intent = finding_intent("ai-draft")
    assert.are.equal("form", intent_mod.mode_of(intent, {}))
    assert.are.equal("ai-draft", intent_mod.mode_of(intent, { body = "x" }))
    assert.are.equal("form", intent_mod.mode_of(finding_intent("form"), { body = "x" }))
  end)

  it("builds the subject of a request from the same fields as the op", function()
    local subject = assert(intent_mod.draft_subject(finding_intent("ai-draft"), {}))
    assert.are.equal("DEP", subject.family)
    assert.are.equal("recommended", subject.severity)
    assert.are.equal("`lua/x.lua:12` in `gitsuite.nvim@0123456`", subject.reference)
  end)

  it("refuses to draft rules.show", function()
    local intent = assert(intent_mod.parse({
      schema = "wkd-intent/1",
      action = "rules.show",
      target = { id = "DEP-01" },
    }))
    local subject, err = intent_mod.draft_subject(intent, {})
    assert.is_nil(subject)
    assert.are.equal("bad_action", err.code)
  end)
end)

describe("rules.agent.draft and :Rules agent --intent", function()
  local base, project, ruleset, cwd_before
  local saved_notify = vim.notify
  local saved_uis = vim.api.nvim_list_uis
  local saved_form_open
  local notes, calls, forms

  ---@param path string
  ---@param text string
  local function write_raw(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local function setup(agent_opts)
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    require("rules").setup({ rulesets = { ruleset }, agent = agent_opts or {} })
    contract.clear_cache()
    require("rules.ui.candidates").reset()
  end

  local function intent_file(mode, finding)
    local path = base .. "/intent.json"
    write_raw(
      path,
      vim.json.encode({
        schema = "wkd-intent/1",
        action = "rules.new",
        mode = mode,
        finding = vim.tbl_extend("force", {
          class = "public",
          repo = "gitsuite.nvim",
          sha = "0123456789abcdef0123456789abcdef01234567",
          where = { file = "lua/x.lua", line = 12 },
          title = "Never call vim.fn in a hot loop",
          family = "DEP",
        }, finding or {}),
      })
    )
    return path
  end

  before_each(function()
    base = vim.fn.tempname()
    ruleset = base .. "/fixture/Checklists"
    write_raw(
      ruleset .. "/_rules/DEP/DEP-01.md",
      table.concat({
        "---",
        "id: DEP-01",
        "severity: recommended",
        "family: DEP",
        "---",
        "",
        "#### `DEP-01` — one",
        "",
        "Text of one.",
        "",
      }, "\n")
    )
    project = base .. "/project"
    write_raw(project .. "/lua/a.lua", "local a = 1\n")
    cwd_before = vim.fn.getcwd()
    vim.fn.chdir(project)
    setup()
    notes, calls, forms = {}, {}, {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { text = tostring(msg), level = level }
    end
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    agent.transport = function(req, cb)
      calls[#calls + 1] = req
      cb(true, { text = answer({ title = "Cache hot calls", body = "Cache the result of expensive calls." }) })
    end
    local ui_cmd = require("rules.ui.cmd")
    saved_form_open = ui_cmd.form_open
    ui_cmd.form_open = function(opts)
      forms[#forms + 1] = opts
    end
  end)

  after_each(function()
    vim.notify = saved_notify
    vim.api.nvim_list_uis = saved_uis
    agent.transport = nil
    require("rules.ui.cmd").form_open = saved_form_open
    vim.fn.chdir(cwd_before)
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
  end)

  local function told(text)
    for _, note in ipairs(notes) do
      if note.text:find(text, 1, true) then
        return true
      end
    end
    return false
  end

  it("sends one request with only the finding fields and fills the form with the draft", function()
    vim.cmd("Rules agent --intent=" .. vim.fn.fnameescape(intent_file("ai-draft")) .. " --yes")
    assert.are.equal(1, #calls)
    assert.is_truthy(calls[1].prompt:find("Never call vim.fn in a hot loop", 1, true))
    assert.is_nil(calls[1].prompt:find(project, 1, true))
    assert.are.equal("ollama", calls[1].provider)
    assert.are.equal(1, #forms)
    assert.are.equal("DEP", forms[1].family)
    assert.are.equal("Cache hot calls", forms[1].title)
    assert.is_truthy(forms[1].text:find("^Cache the result of expensive calls%."))
    assert.is_truthy(forms[1].text:find("Evidence:", 1, true))
  end)

  it("sends nothing in mode form and opens the form with the plain finding", function()
    vim.cmd("Rules agent --intent=" .. vim.fn.fnameescape(intent_file("form")))
    assert.are.equal(0, #calls)
    assert.are.equal(1, #forms)
    assert.are.equal("Never call vim.fn in a hot loop", forms[1].title)
  end)

  it("sends nothing when the question is declined, and the form still opens plain", function()
    local original = confirm.yesno
    confirm.yesno = function(_, _, cb)
      cb(false)
    end
    vim.cmd("Rules agent --intent=" .. vim.fn.fnameescape(intent_file("ai-draft")))
    confirm.yesno = original
    assert.are.equal(0, #calls)
    assert.is_true(told("nothing was sent"))
    assert.are.equal(1, #forms)
    assert.are.equal("Never call vim.fn in a hot loop", forms[1].title)
  end)

  it("refuses a backend that is not local while agent.backends is empty", function()
    vim.cmd("Rules agent --intent=" .. vim.fn.fnameescape(intent_file("ai-draft")) .. " --yes --backend=openai")
    assert.are.equal(0, #calls)
    assert.is_true(told("is not local"))
    assert.are.equal(1, #forms)
  end)

  it("keeps a bad answer out of the form: the plain text of the finding is used", function()
    agent.transport = function(req, cb)
      calls[#calls + 1] = req
      cb(true, { text = answer({ body = "see /home/x/secret.lua" }) })
    end
    vim.cmd("Rules agent --intent=" .. vim.fn.fnameescape(intent_file("ai-draft")) .. " --yes")
    assert.are.equal(1, #calls)
    assert.is_true(told("path of another machine"))
    assert.are.equal(1, #forms)
    assert.is_nil(forms[1].text:find("/home/x", 1, true))
  end)

  it("tells a failed request and still opens the plain form", function()
    agent.transport = function(_, cb)
      cb(false, { message = "connection refused" })
    end
    vim.cmd("Rules agent --intent=" .. vim.fn.fnameescape(intent_file("ai-draft")) .. " --yes")
    assert.is_true(told("connection refused"))
    assert.are.equal(1, #forms)
  end)

  it("refuses an intent the engine refuses before anything is sent", function()
    vim.cmd("Rules agent --intent=" .. vim.fn.fnameescape(intent_file("ai-draft", { class = "private" })) .. " --yes")
    assert.are.equal(0, #calls)
    assert.are.equal(0, #forms)
    assert.is_true(told("bad_class"))
  end)

  it("says so when the intent file cannot be read", function()
    vim.cmd("Rules agent --intent=" .. vim.fn.fnameescape(base .. "/missing.json"))
    assert.is_true(told("cannot read the intent file"))
  end)
end)
