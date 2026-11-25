-- TESTS/views_bytes_spec.lua -- the bytes of a saved view in the vault: the text a view is written as, and what a change
-- of it leaves. The texts below are what the files had before the shape of a view moved to `lib.nvim.view_file`; they
-- must not change, the files are the user's.
---@diagnostic disable: need-check-nil
local views = require("rules.views")

local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return (path:gsub("\\", "/"))
end

local function read_raw(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local FULL = "---\ntitle: Everything\ndisplay: matrix\ngroup_by: family\ngroup_by2: layout:alpha:regeln/DEP.md\n"
  .. "collapsed: [DEP, SEC]\nsel_families: [DEP, SEC]\nsel_severities: [critical]\nsel_statuses: [open]\n"
  .. "sel_rulesets: [alpha]\nsel_query: pin it\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\n"
local PATCHED = "---\ntitle: Everything\ndisplay: list\ngroup_by: severity\ncreated: 2026-01-01\nupdated: 2026-02-02\n---\n\n"
local MINIMAL = "---\ntitle: Plain\ndisplay: columns\ngroup_by: status\ncreated: 2026-03-03\nupdated: 2026-03-03\n---\n\n"

describe("rules.views: the bytes of a view file", function()
  it("writes, changes and reads a view as the files always were", function()
    local root = tmp_dir()
    local full = {
      title = "Everything",
      display = "matrix",
      group_by = "family",
      group_by2 = "layout:alpha:regeln/DEP.md",
      collapsed = { "DEP", "SEC" },
      select = {
        families = { "DEP", "SEC" },
        severities = { "critical" },
        statuses = { "open" },
        rulesets = { "alpha" },
        query = "pin it",
      },
    }
    local made = assert(views.save(root, full, { today = "2026-01-01" }))
    assert.are.equal("everything", made.id)
    assert.are.equal(FULL, read_raw(root .. "/views/everything.md"))

    local read = views.all(root)
    assert.are.same({ "DEP", "SEC" }, read[1].select.families)

    local mini = { title = "Everything", display = "list", group_by = "severity" }
    assert(views.save(root, mini, { id = made.id, if_match = made.etag_after, today = "2026-02-02" }))
    assert.are.equal(PATCHED, read_raw(root .. "/views/everything.md"))

    local plain =
      assert(views.save(root, { title = "Plain", display = "columns", group_by = "status" }, { today = "2026-03-03" }))
    assert.are.equal(MINIMAL, read_raw(root .. "/views/" .. plain.id .. ".md"))
  end)
end)
