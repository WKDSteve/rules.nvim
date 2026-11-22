-- TESTS/layout_carried_spec.lua -- a layout that carries a rule by another token than `{{rule ID}}` (`{{family FAM}}`,
-- `{{family FAM brief}}`, `{{refer FAM}}`, `{{brief ID}}`): the editor refuses a second placement there, naming the
-- token; `retire` and `reinstate` leave such a layout alone; `--to=` does not offer it.
---@diagnostic disable: need-check-nil
local layout_edit = require("rules.engine.layout_edit")
local json = require("lib.nvim.json.canonical")
local ops = require("rules.ops")

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string|nil
local function read_raw(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@param lines string[]
---@return string
local function doc(lines)
  return table.concat(lines, "\n") .. "\n"
end

---@param id string
---@return string
local function rule_file(id)
  return doc({
    "---",
    "id: " .. id,
    "severity: recommended",
    "family: " .. id:match("^(%a+)%-"),
    "---",
    "",
    "#### `" .. id .. "` — title of " .. id,
    "",
    "Text of " .. id .. ".",
    "",
    "---",
    "",
  })
end

---@param body string[]
---@param output? string
---@return string
local function layout(body, output)
  return doc(vim.list_extend({ "---", "kind: layout", "output: " .. (output or "regeln/X.md"), "---" }, body))
end

describe("layout_edit: a layout that carries the rule", function()
  it("finds the {{family}}, {{refer}} and {{brief}} token that carries a rule, with its line", function()
    local text = layout({ "# K", "", "{{family DEP brief}}  ", "", "{{refer LP}}", "", "{{brief ERR-02}}" })
    assert.are.same({ line = 7, token = "{{family DEP brief}}", kind = "family" }, layout_edit.carried(text, "DEP-07"))
    assert.are.same({ line = 9, token = "{{refer LP}}", kind = "refer" }, layout_edit.carried(text, "LP-01"))
    assert.are.same({ line = 11, token = "{{brief ERR-02}}", kind = "brief" }, layout_edit.carried(text, "ERR-02"))
    assert.is_nil(layout_edit.carried(text, "ERR-01"))
    assert.is_nil(layout_edit.carried(text, "DEPX-01"))
    assert.are.same(7, layout_edit.carried_family(text, "DEP").line)
    assert.are.same("refer", layout_edit.carried_family(text, "LP").kind)
    -- a brief token is one rule, not its family
    assert.is_nil(layout_edit.carried_family(text, "ERR"))
  end)

  it("reads the tokens behind the frontmatter only, but in a fence or a comment too (the generator fills those)", function()
    local front = doc({ "---", "kind: layout", "output: x.md", "note: {{family DEP}}", "---", "# K" })
    assert.is_nil(layout_edit.carried(front, "DEP-01"))
    local fenced = layout({ "# K", "", "```", "{{family DEP}}", "```" })
    assert.are.same(8, layout_edit.carried(fenced, "DEP-01").line)
    local commented = layout({ "# K", "", "<!--", "{{refer DEP}}", "-->" })
    assert.are.same("refer", layout_edit.carried(commented, "DEP-01").kind)
  end)

  it("refuses to place a rule into a layout that carries it, naming the token", function()
    local text = layout({ "# K", "", "## A", "", "{{family DEP}}", "", "{{refer LP}}", "", "{{brief ERR-02}}", "" })
    local out, why = layout_edit.place(text, "DEP-03", { section = "A" })
    assert.is_nil(out)
    assert.is_truthy(why:find("{{family DEP}} (line 9)", 1, true), why)
    assert.is_truthy(why:find("would place it twice", 1, true), why)
    out, why = layout_edit.place(text, "LP-02", { top = true })
    assert.is_nil(out)
    assert.is_truthy(why:find("{{refer LP}} (line 11)", 1, true), why)
    assert.is_truthy(why:find("read in another document", 1, true), why)
    out, why = layout_edit.place(text, "ERR-02", { section = "A", first = true })
    assert.is_nil(out)
    assert.is_truthy(why:find("as {{brief ERR-02}} (line 13)", 1, true), why)
    -- another rule of another family still goes in
    assert.is_truthy(layout_edit.place(text, "ERR-01", { section = "A" }))
  end)
end)

describe("rules-ops/1 and a layout that carries a family", function()
  local root, opts, kurz, regeln

  before_each(function()
    root = vim.fn.tempname() .. "/fixture/Checklists"
    for _, id in ipairs({ "DEP-01", "DEP-02", "ERR-01" }) do
      write_raw(("%s/_rules/%s/%s.md"):format(root, id:match("^(%a+)"), id), rule_file(id))
    end
    kurz = root .. "/_kontext/kurz.md"
    write_raw(kurz, layout({ "# Kurz", "", "## Abh", "", "{{family DEP brief}}", "", "## Err", "" }, "kontext/kurz.md"))
    regeln = root .. "/_layouts/regeln.md"
    write_raw(regeln, layout({ "# Regeln", "", "## Err", "", "{{rule ERR-01}}", "" }, "regeln.md"))
    opts = { rulesets = { root }, today = "2026-11-22" }
  end)

  ---@param op table
  ---@return table entry
  local function one(op)
    local result, err = ops.run({ ops = { op } }, opts)
    assert(result, vim.inspect(err))
    return result.results[1]
  end

  it("refuses a new rule of the family in that layout, and leaves every file as it was", function()
    local before = read_raw(kurz)
    local entry =
      one({ op = "new", family = "DEP", title = "three", severity = "critical", section = "Abh", layout = "kontext/kurz.md" })
    assert.is_false(entry.ok, vim.inspect(entry))
    assert.is_truthy(entry.error.message:find("{{family DEP brief}} (line 9)", 1, true), vim.inspect(entry))
    assert.are.equal(before, read_raw(kurz))
    assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))
  end)

  it("refuses to move a rule of the family into that layout", function()
    local before = read_raw(kurz)
    local entry = one({ op = "move", id = "DEP-02", section = "Err", layout = "kontext/kurz.md" })
    assert.is_false(entry.ok, vim.inspect(entry))
    assert.is_truthy(entry.error.message:find("{{family DEP brief}}", 1, true), vim.inspect(entry))
    assert.are.equal(before, read_raw(kurz))
  end)

  it("retires a rule the family token carries without touching that layout, and says so when it comes back", function()
    local before = read_raw(kurz)
    local retired = one({ op = "retire", id = "DEP-02" })
    assert.is_true(retired.ok, vim.inspect(retired))
    assert.are.equal(before, read_raw(kurz))
    local inverse = vim.json.decode(json.encode(retired.inverse))
    assert.is_nil(inverse.places)
    local back = one(inverse)
    assert.is_true(back.ok, vim.inspect(back))
    assert.is_nil(back.placed)
    assert.is_nil(back.warnings)
    assert.are.same({ "kontext/kurz.md" }, vim.json.decode(json.encode(back.carried)))
    assert.are.equal(before, read_raw(kurz))
  end)

  it("says the family token carries the rule when the place kept in the retired file no longer fits", function()
    write_raw(regeln, layout({ "# Regeln", "", "## Err", "", "{{rule ERR-01}}", "{{rule DEP-01}}", "" }, "regeln.md"))
    local retired = one({ op = "retire", id = "DEP-01" })
    assert.is_true(retired.ok, vim.inspect(retired))
    -- the layout the rule stood in takes the whole family now: the kept place is refused there
    write_raw(regeln, layout({ "# Regeln", "", "## Err", "", "{{rule ERR-01}}", "{{family DEP}}", "" }, "regeln.md"))
    local back = one({ op = "reinstate", id = "DEP-01" })
    assert.is_true(back.ok, vim.inspect(back))
    assert.is_nil(back.placed)
    local warnings = vim.json.decode(json.encode(back.warnings))
    local said = "the place kept in the retired file no longer fits: the rule is only in kontext/kurz.md, regeln.md,"
      .. " by its family token"
    assert.are.same({ said }, warnings)
  end)

  it("names no carrier for a rule no family token holds", function()
    local retired = one({ op = "retire", id = "ERR-01" })
    local back = one(vim.json.decode(json.encode(retired.inverse)))
    assert.is_true(back.ok, vim.inspect(back))
    assert.is_nil(back.carried)
    assert.are.same({ "regeln.md" }, back.placed.layouts)
  end)
end)

describe("rules.ui.candidates.places and a layout that carries a family", function()
  local candidates = require("rules.ui.candidates")
  local contract = require("rules.contract")
  local root

  before_each(function()
    root = vim.fn.tempname() .. "/fixture/Checklists"
    write_raw(root .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01"))
    write_raw(root .. "/_rules/ERR/ERR-01.md", rule_file("ERR-01"))
    write_raw(root .. "/_kontext/kurz.md", layout({ "# Kurz", "", "## Abh", "", "{{family DEP brief}}" }, "kontext/kurz.md"))
    write_raw(root .. "/_layouts/regeln.md", layout({ "# Regeln", "", "## Err", "", "{{rule ERR-01}}" }, "regeln.md"))
    require("rules.config").setup({ rulesets = { root } })
    contract.clear_cache()
    candidates.reset()
  end)

  after_each(function()
    require("rules.config").setup({ rulesets = {} })
    contract.clear_cache()
    candidates.reset()
  end)

  it("leaves out the layout that carries the family of :Rules new or the rule of :Rules move", function()
    assert.are.same({ "kontext/kurz.md", "regeln.md" }, candidates.places(""))
    assert.are.same({ "regeln.md" }, candidates.places("", "Rules new DEP five --to="))
    assert.are.same({ "regeln.md" }, candidates.places("", "Rules move DEP-01 --to="))
    assert.are.same({}, candidates.places("kontext/kurz.md#", "Rules move DEP-01 --to=kontext/kurz.md#"))
    -- another family, another command, or the argument not typed yet: every layout
    assert.are.same({ "kontext/kurz.md", "regeln.md" }, candidates.places("", "Rules new ERR x --to="))
    assert.are.same(
      { "kontext/kurz.md#Kurz", "kontext/kurz.md#Abh" },
      candidates.places("kontext/kurz.md#", "Rules new ERR --to=kontext/kurz.md#")
    )
    assert.are.same({ "kontext/kurz.md", "regeln.md" }, candidates.places("", "Rules reinstate DEP-01 --to="))
    assert.are.same({ "kontext/kurz.md", "regeln.md" }, candidates.places("", "Rules new --to="))
  end)
end)
