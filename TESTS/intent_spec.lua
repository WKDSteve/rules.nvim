-- TESTS/intent_spec.lua -- `rules.intent`: the intents rules.show and rules.new of `wkd-intent/1`.
---@diagnostic disable: need-check-nil
local intent_mod = require("rules.intent")

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@return string
local function read_raw(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@return string root, table opts
local function fixture()
  local root = vim.fn.tempname() .. "/fixture/Checklists"
  vim.fn.mkdir(root, "p")
  write_raw(
    root .. "/_rules/DEP/DEP-01.md",
    table.concat(
      { "---", "id: DEP-01", "severity: recommended", "family: DEP", "---", "", "#### `DEP-01` — one", "", "Text of one.", "" },
      "\n"
    )
  )
  return root, { rulesets = { root }, today = "2026-10-14" }
end

---@param over? table
---@return table
local function finding_intent(over)
  local base = {
    schema = "wkd-intent/1",
    action = "rules.new",
    mode = "form",
    source = { app = "testing", finding = "0123456789abcdef" },
    finding = {
      schema = "testing-finding/1",
      class = "public",
      repo = "gitsuite.nvim",
      sha = "0123456789abcdef0123456789abcdef01234567",
      where = { file = "lua/x.lua", line = 12 },
      title = "Never call vim.fn in a hot loop",
      rule = "DEP-01",
    },
    target = nil,
  }
  return vim.tbl_deep_extend("force", base, over or {})
end

describe("rules.intent.parse", function()
  it("accepts a well-formed intent and defaults the mode to form", function()
    local data = finding_intent()
    data.mode = nil
    local intent = assert(intent_mod.parse(data))
    assert.are.equal("rules.new", intent.action)
    assert.are.equal("form", intent.mode)
  end)

  it("accepts the JSON text as well as a table", function()
    local intent = assert(intent_mod.parse(vim.json.encode(finding_intent())))
    assert.are.equal("rules.new", intent.action)
  end)

  it("refuses an action that belongs to another engine", function()
    local _, err = intent_mod.parse(finding_intent({ action = "tasks.new" }))
    assert.are.equal("bad_action", err.code)
  end)

  it("refuses a wrong schema, mode or a text that is not JSON", function()
    assert.are.equal("bad_schema", select(2, intent_mod.parse(finding_intent({ schema = "x/1" }))).code)
    assert.are.equal("bad_mode", select(2, intent_mod.parse(finding_intent({ mode = "run" }))).code)
    assert.are.equal("bad_json", select(2, intent_mod.parse("{nope")).code)
  end)

  it("refuses a wrong data class: private, unclassified and a missing one", function()
    for _, class in ipairs({ "private", "unclassified", "tricentis" }) do
      local _, err = intent_mod.parse(finding_intent({ finding = { class = class } }))
      assert.are.equal("bad_class", err.code, class)
    end
    local data = finding_intent()
    data.finding.class = nil
    assert.are.equal("bad_class", select(2, intent_mod.parse(data)).code)
  end)

  it("refuses a path of another machine anywhere in the intent", function()
    for _, path in ipairs({ "C:\\Users\\x\\a.lua", "/home/x/a.lua", "\\\\host\\share\\a" }) do
      local _, err = intent_mod.parse(finding_intent({ finding = { where = { file = path } } }))
      assert.are.equal("absolute_path", err.code, path)
    end
  end)

  it("refuses multi-line values and a non-integer line, which would end up in the rule text", function()
    local bad = {
      { title = "one\n#### `X-1` injected" },
      { repo = "a\nb" },
      { where = { file = "lua/x.lua\n# h" } },
      { where = { file = "lua/x.lua", line = 1.5 } },
      { where = { file = "lua/x.lua", line = -1 } },
      { where = "lua/x.lua" },
    }
    for i, over in ipairs(bad) do
      local _, err = intent_mod.parse(finding_intent({ finding = over }))
      assert.are.equal("bad_field", err and err.code, "case " .. i)
    end
    assert.is_truthy(intent_mod.parse(finding_intent({ finding = { where = { file = "lua/x.lua", line = 7 } } })))
  end)

  it("refuses an intent above the size limit before decoding it", function()
    local big = vim.json.encode(finding_intent({ finding = { title = "t" } })) .. string.rep(" ", intent_mod.MAX_BYTES)
    assert.are.equal("too_large", select(2, intent_mod.parse(big)).code)
  end)

  it("refuses an over-long title", function()
    local _, err = intent_mod.parse(finding_intent({ finding = { title = string.rep("a", intent_mod.MAX_TITLE + 1) } }))
    assert.are.equal("bad_field", err.code)
  end)
end)

describe("rules.intent.run", function()
  it("shows a rule through the read door", function()
    local _, opts = fixture()
    local intent = assert(intent_mod.parse(finding_intent({ action = "rules.show", target = { id = "DEP-01" } })))
    local result = assert(intent_mod.run(intent, opts))
    assert.are.equal("DEP-01", result.document.rule.id)
  end)

  it("reports an unknown rule id instead of raising", function()
    local _, opts = fixture()
    local intent = assert(intent_mod.parse(finding_intent({ action = "rules.show", target = { id = "DEP-99" } })))
    local result, err = intent_mod.run(intent, opts)
    assert.is_nil(result)
    assert.are.equal("no_target", err.code)
  end)

  it("drafts a new rule as a dry run and writes nothing without confirmation", function()
    local root, opts = fixture()
    local intent = assert(intent_mod.parse(finding_intent()))
    local result = assert(intent_mod.run(intent, opts))
    assert.is_true(result.dry_run)
    assert.are.equal("would_create", result.document.results[1].outcome)
    assert.are.equal("", read_raw(root .. "/_rules/DEP/DEP-02.md"))
  end)

  it("saves with confirmation and carries the evidence as a reference, not the excerpt", function()
    local root, opts = fixture()
    opts.yes = true
    local data = finding_intent()
    data.finding.excerpt = "SECRET-EXCERPT"
    local intent = assert(intent_mod.parse(data))
    local result = assert(intent_mod.run(intent, opts))
    assert.is_false(result.dry_run)
    local text = read_raw(root .. "/_rules/DEP/DEP-02.md")
    assert.is_truthy(text:find("Never call vim.fn in a hot loop", 1, true))
    assert.is_truthy(text:find("`lua/x.lua:12`", 1, true))
    assert.is_truthy(text:find("`gitsuite.nvim@0123456`", 1, true))
    assert.is_nil(text:find("SECRET-EXCERPT", 1, true))
  end)

  it("takes the family from the option first, then from the rule id of the finding", function()
    local intent = assert(intent_mod.parse(finding_intent()))
    assert.are.equal("DEP", intent_mod.new_op(intent).family)
    assert.are.equal("ERR", intent_mod.new_op(intent, { family = "ERR" }).family)
  end)

  it("asks for a family instead of guessing one", function()
    local data = finding_intent()
    data.finding.rule = nil
    local intent = assert(intent_mod.parse(data))
    local op, err = intent_mod.new_op(intent)
    assert.is_nil(op)
    assert.are.equal("no_family", err.code)
  end)

  it("lets the ops door refuse an unknown family spelling", function()
    local _, opts = fixture()
    local intent = assert(intent_mod.parse(finding_intent()))
    opts.family = "Fix"
    local result, err = intent_mod.run(intent, opts)
    assert.is_nil(result)
    assert.is_truthy(err)
  end)
end)
