-- TESTS/catalog_brief_spec.lua -- compact documents of a ruleset: the brief form of a rule, the family tokens
-- (`{{family FAM}}`, `{{family FAM brief}}`, `{{refer FAM}}`, `{{brief ID}}`), `families: all` and `folder`.
---@diagnostic disable: need-check-nil
local catalog = require("rules.engine.catalog")
local parser = require("rules.engine.parser")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return (path:gsub("\\", "/"))
end

---@param path string
---@param text string
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@param id string
---@param body string
---@return string
local function rule_text(id, body)
  return ("---\nid: %s\nseverity: critical\n---\n\n%s"):format(id, body)
end

---@param id string
---@param body string
---@return Rules.RuleFile
local function rule_file(id, body)
  local path = tmp_dir() .. "/" .. id .. ".md"
  write(path, rule_text(id, body))
  local file, errs = parser.read_rule_file(path)
  assert(file, errs and errs[1])
  return file
end

---@param front string[]  frontmatter lines besides `kind`
---@param lines string[]
---@return string
local function layout_text(front, lines)
  return ("---\nkind: layout\n%s\n---\n%s\n"):format(table.concat(front, "\n"), table.concat(lines, "\n"))
end

---@param results Rules.CatalogResult[]
---@return string[]
local function problems_of(results)
  local out = {}
  for _, result in ipairs(results) do
    vim.list_extend(out, result.problems)
  end
  return out
end

describe("rules.engine.catalog.brief_lines", function()
  it("gives id, title and the rule paragraphs as one list item, without reason and evidence", function()
    local file = rule_file(
      "GIT-01",
      "#### `GIT-01` — Fertig heißt gepusht\n\nIst eine Aufgabe fertig,\nsofort pushen.\n\n"
        .. "Zweiter Absatz\n  eingerückt.\n\n- eins\n- zwei\n\nBegründung: weil.\n\nBeleg: hier.\n\n---\n"
    )
    assert.are.same({
      "- `GIT-01` **Fertig heißt gepusht**: Ist eine Aufgabe fertig, sofort pushen.",
      "  Zweiter Absatz eingerückt.",
      "  - eins",
      "  - zwei",
    }, catalog.brief_lines(file))
  end)

  it("stops at Beleg: as well, and puts a list that comes first under the item line", function()
    local file = rule_file("A-1", "## `A-1` — T\n\n1. erst\n2. dann\n\nBeleg: x\n")
    assert.are.same({ "- `A-1` **T**:", "  1. erst", "  2. dann" }, catalog.brief_lines(file))
  end)

  it("keeps a heading that does not start with the id as the title", function()
    local file = rule_file("A-1", "## Eine Regel\n\nText.\n")
    assert.are.same({ "- `A-1` **Eine Regel**: Text." }, catalog.brief_lines(file))
  end)

  it("leaves out the rule block and stops at the next heading", function()
    local file = rule_file(
      "A-1",
      '## `A-1` — T\n\n```rule\ncheck = { type = "grep", pattern = "x" },\n```\n\nText.\n\n## Anderes\n\nNicht.\n'
    )
    assert.are.same({ "- `A-1` **T**: Text." }, catalog.brief_lines(file))
  end)

  it("refuses a fenced block in the rule text, and takes one below Begründung:", function()
    local bad = rule_file("A-1", "## `A-1` — T\n\nText.\n\n```lua\nx()\n```\n")
    local lines, err = catalog.brief_lines(bad)
    assert.is_nil(lines)
    assert.matches("fenced block", err)

    local good = rule_file("A-2", "## `A-2` — T\n\nText.\n\nBegründung: so.\n\n```markdown\n## H\n\nBeleg: x\n```\n")
    assert.are.same({ "- `A-2` **T**: Text." }, catalog.brief_lines(good))
  end)

  it("refuses a rule with no text before the reason", function()
    local file = rule_file("A-1", "## `A-1` — T\n\nBegründung: nur das.\n")
    local lines, err = catalog.brief_lines(file)
    assert.is_nil(lines)
    assert.matches("no rule text", err)
  end)
end)

describe("rules.engine.catalog.parse_token", function()
  it("reads the rule and family tokens", function()
    assert.are.same({ kind = "rule", name = "A-1" }, catalog.parse_token("{{rule A-1}}"))
    assert.are.same({ kind = "brief", name = "A-1" }, catalog.parse_token("{{brief A-1}}  "))
    assert.are.same({ kind = "family", name = "GIT", brief = false }, catalog.parse_token("{{family GIT}}"))
    assert.are.same({ kind = "family", name = "GIT", brief = true }, catalog.parse_token("{{family GIT brief}}"))
    assert.are.same({ kind = "refer", name = "LP" }, catalog.parse_token("{{refer LP}}"))
  end)

  it("takes anything else for text", function()
    for _, line in ipairs({
      " {{family GIT}}",
      "{{family GIT long}}",
      "{{refer LP brief}}",
      "{{brief A-1 brief}}",
      "{{toc}}",
      "{{other X}}",
      "text {{family GIT}}",
      "{{family}}",
    }) do
      assert.is_nil(catalog.parse_token(line), line)
    end
  end)
end)

describe("rules.engine.catalog.render with family tokens", function()
  local files = {
    ["DEP-1"] = rule_file("DEP-1", "## `DEP-1` — Eins\n\nText eins.\n"),
    ["DEP-2"] = rule_file("DEP-2", "## `DEP-2` — Zwei\n\nText zwei.\n"),
    ["DEP-10"] = rule_file("DEP-10", "## `DEP-10` — Zehn\n\nText zehn.\n"),
    ["LP-1"] = rule_file("LP-1", "## `LP-1` — Lern\n\nText.\n"),
  }
  local function lookup(id)
    return files[id], files[id] and nil or "not loaded"
  end
  local families = catalog.families_of(vim.tbl_keys(files))

  it("puts in every rule of the family in the order of the numbers", function()
    local text, problems, used, placed = catalog.render(
      { output = "x.md", lines = { "# T", "", "{{family DEP brief}}", "", "{{refer LP}}", "Ende" } },
      lookup,
      nil,
      families
    )
    assert.are.same({}, problems)
    assert.are.equal(
      "# T\n\n- `DEP-1` **Eins**: Text eins.\n- `DEP-2` **Zwei**: Text zwei.\n- `DEP-10` **Zehn**: Text zehn.\n\nEnde\n",
      text
    )
    assert.are.same({ "DEP-1", "DEP-2", "DEP-10" }, used)
    assert.are.same({ "DEP", "LP" }, placed)
  end)

  it("renders the whole rules without brief, and one rule brief with {{brief ID}}", function()
    local text = catalog.render({ output = "x.md", lines = { "{{family LP}}", "{{brief DEP-2}}" } }, lookup, nil, families)
    assert.matches('```rule\nid = "LP%-1",', text)
    assert.matches("\n%- `DEP%-2` %*%*Zwei%*%*: Text zwei%.\n$", text)
  end)

  it("refuses a family placed twice, a rule placed by a family and by itself, and an unknown family", function()
    local text, problems = catalog.render(
      { output = "x.md", lines = { "{{family DEP}}", "{{refer DEP}}", "{{rule DEP-2}}", "{{family NONE brief}}" } },
      lookup,
      nil,
      families
    )
    assert.is_nil(text)
    assert.are.same({
      "layout line 2: family DEP is placed twice (line 1)",
      "layout line 3: rule DEP-2 is placed twice (line 1)",
      "layout line 4: family NONE has no rule file",
    }, problems)
  end)
end)

describe("rules.engine.catalog.parse_layout with families and folder", function()
  it("reads both keys", function()
    local layout = catalog.parse_layout(layout_text({ "output: kontext/a.md", "folder: kontext", "families: all" }, {}))
    assert.are.equal("kontext", layout.folder)
    assert.are.equal("all", layout.families)
  end)

  it("refuses another value of families, an output outside the folder and a bad folder", function()
    local _, err = catalog.parse_layout(layout_text({ "output: a.md", "families: some" }, {}))
    assert.matches("`families` can only be `all`", err)
    _, err = catalog.parse_layout(layout_text({ "output: other/a.md", "folder: kontext" }, {}))
    assert.matches("is not inside `folder`", err)
    _, err = catalog.parse_layout(layout_text({ "output: kontext/a.md", "folder: ../kontext" }, {}))
    assert.matches("`folder` must be", err)
    _, err = catalog.parse_layout(layout_text({ "output: kontextual/a.md", "folder: kontext" }, {}))
    assert.matches("is not inside `folder`", err)
  end)
end)

describe("rules.engine.catalog.build of compact documents", function()
  ---@return string root
  local function ruleset()
    local root = tmp_dir()
    write(root .. "/_rules/GIT/GIT-01.md", rule_text("GIT-01", "#### `GIT-01` — Eins\n\nText eins.\n\nBeleg: x.\n"))
    write(root .. "/_rules/GIT/GIT-02.md", rule_text("GIT-02", "#### `GIT-02` — Zwei\n\nText zwei.\n"))
    write(root .. "/_rules/LP/LP-01.md", rule_text("LP-01", "#### `LP-01` — Lern\n\nText.\n"))
    write(
      root .. "/_kontext/allgemein.md",
      layout_text(
        { "output: kontext/allgemein.md", "folder: kontext", "families: all" },
        { "# Regeln", "", "{{family GIT brief}}", "", "## Lernen", "", "{{refer LP}}", "- `LP` steht in regeln/LP.md" }
      )
    )
    return root
  end

  it("writes the compact document, and a new rule of the family shows without a change to the layout", function()
    local root = ruleset()
    local results, errors = catalog.build(root)
    assert.are.same({}, errors)
    assert.are.same({}, problems_of(results))
    assert.are.equal(
      catalog.header("_kontext/allgemein.md")
        .. "\n# Regeln\n\n- `GIT-01` **Eins**: Text eins.\n- `GIT-02` **Zwei**: Text zwei.\n\n## Lernen\n\n"
        .. "- `LP` steht in regeln/LP.md\n",
      read(root .. "/kontext/allgemein.md")
    )

    write(root .. "/_rules/GIT/GIT-03.md", rule_text("GIT-03", "#### `GIT-03` — Drei\n\nText drei.\n"))
    assert.are.equal("stale", catalog.build(root, { check = true })[1].status)
    catalog.build(root)
    assert.is_truthy(read(root .. "/kontext/allgemein.md"):find("- `GIT-03` **Drei**: Text drei.\n", 1, true))
  end)

  it("says a family that stands in no layout with families: all, and one that stands in two", function()
    local root = ruleset()
    write(root .. "/_rules/NEW/NEW-01.md", rule_text("NEW-01", "#### `NEW-01` — Neu\n\nText.\n"))
    local results = catalog.build(root, { check = true })
    assert.are.same({ "family NEW stands in no layout with `families: all` (_kontext/allgemein.md)" }, problems_of(results))

    write(
      root .. "/_kontext/zweit.md",
      layout_text({ "output: kontext/zweit.md", "folder: kontext", "families: all" }, { "{{refer NEW}}", "{{refer GIT}}" })
    )
    results = catalog.build(root, { check = true })
    assert.are.same({ "_kontext/zweit.md: family GIT stands in _kontext/allgemein.md already" }, problems_of(results))
  end)

  it("does not ask for the families without families: all", function()
    local root = ruleset()
    write(root .. "/_kontext/allgemein.md", layout_text({ "output: kontext/allgemein.md" }, { "{{family GIT brief}}" }))
    assert.are.same({}, problems_of(catalog.build(root, { check = true })))
  end)

  it("removes a stale generated document of the folder, says it with check, and never touches another file", function()
    local root = ruleset()
    catalog.build(root)
    write(root .. "/kontext/old.md", catalog.header("_kontext/old.md") .. "\nalt\n")

    local results = catalog.build(root, { check = true })
    assert.are.equal("stale", results[#results].status)
    assert.matches("kontext/old.md is made by no layout of `folder` kontext", results[#results].problems[1])
    assert.is_truthy(read(root .. "/kontext/old.md"))

    results = catalog.build(root)
    assert.are.equal("removed", results[#results].status)
    assert.is_nil(read(root .. "/kontext/old.md"))
    assert.are.same({}, problems_of(results))

    write(root .. "/kontext/sub/hand.md", "# von Hand\n")
    write(root .. "/kontext/notes.txt", "x\n")
    results = catalog.build(root)
    assert.are.same({
      "kontext/notes.txt is in `folder` kontext, which holds generated documents only; move it",
      "kontext/sub/hand.md is in `folder` kontext, which holds generated documents only; move it",
    }, problems_of(results))
    assert.is_truthy(read(root .. "/kontext/sub/hand.md"))
  end)

  it("keeps a stale document when the build had an error", function()
    local root = ruleset()
    catalog.build(root)
    write(root .. "/kontext/old.md", catalog.header("_kontext/old.md") .. "\nalt\n")
    write(root .. "/_kontext/broken.md", layout_text({ "output: kontext/broken.md", "folder: kontext" }, { "{{family X}}" }))
    local results = catalog.build(root)
    assert.is_truthy(read(root .. "/kontext/old.md"))
    local said = table.concat(problems_of(results), "\n")
    assert.matches("kontext/old.md is made by no layout of `folder` kontext; kept", said)
  end)

  it("takes the outputs of a layout with a folder inside the folder as its own", function()
    local root = ruleset()
    write(root .. "/_kontext/ws.md", layout_text({ "output: kontext/ws/falcon.md", "folder: kontext/ws" }, { "# Falcon" }))
    local results = catalog.build(root)
    assert.are.same({}, problems_of(results))
    assert.is_truthy(read(root .. "/kontext/ws/falcon.md"))
    assert.are.same({}, problems_of(catalog.build(root, { check = true })))
  end)

  it("does not load the compact documents as rules", function()
    local root = ruleset()
    catalog.build(root)
    local rules, errors = require("rules.engine.loader").load({ root })
    assert.are.same({}, errors)
    assert.are.equal(3, #rules)
  end)
end)
