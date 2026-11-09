-- TESTS/views_spec.lua -- the saved views of the rules (`rules.views`, `view_save`, `view_delete`): what a view may say,
-- where its file goes, the version a change is made on, the inverse of each operation, and a file that is no view.
---@diagnostic disable: need-check-nil
local ops = require("rules.ops")
local api = require("rules.api")
local views = require("rules.views")

local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return (path:gsub("\\", "/"))
end

local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function read_raw(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

local RULE = "---\nid: DEP-01\nseverity: critical\nfamily: DEP\n---\n\n#### `DEP-01` — Pin it\n\nPin the version.\n"

local function make_vault()
  local root = tmp_dir()
  write_raw(root .. "/rulesets/alpha/_rules/DEP/DEP-01.md", RULE)
  return root
end

---@param root string
---@param op table
---@param dry? boolean
---@return table entry
local function run(root, op, dry)
  local doc, err = ops.run({ ops = { op }, dry_run = dry or false }, { vault = root, today = "2026-01-01" })
  assert(doc, vim.inspect(err))
  return doc.results[1]
end

---@param root string
---@return table doc
local function views_doc(root)
  local text, code = api.call("views", nil, { vault = root })
  assert.is_nil(code, text)
  return vim.json.decode(text)
end

local SEVERITY = { title = "By severity", display = "columns", group_by = "severity" }

describe("rules.views: what a view may say", function()
  it("takes a title, a way to draw it and a field to group by, a layout too, and a second field for a matrix", function()
    assert.is_truthy(views.normalize(SEVERITY))
    assert.is_truthy(views.normalize({ title = "L", display = "list", group_by = "layout:alpha:regeln/DEP.md" }))
    assert.is_truthy(views.normalize({ title = "M", display = "matrix", group_by = "family", group_by2 = "status" }))
  end)

  it("refuses what is not a view, each with its reason", function()
    local cases = {
      { { display = "columns", group_by = "severity" }, "needs a title" },
      { { title = "x", display = "board", group_by = "severity" }, "display 'board' is unknown" },
      { { title = "x", display = "columns", group_by = "prio" }, "group_by 'prio' is not a field" },
      { { title = "x", display = "columns", group_by = "layout:alpha" }, "is not a field" },
      { { title = "x", display = "matrix", group_by = "severity" }, "a matrix needs group_by2" },
      { { title = "x", display = "list", group_by = "severity", group_by2 = "family" }, "for a matrix only" },
      { { title = "x", display = "matrix", group_by = "family", group_by2 = "family" }, "another field" },
      { { title = "a\tb", display = "list", group_by = "family" }, "control character" },
      { { title = "x", display = "list", group_by = "family", select = { tags = { "a" } } }, "unknown entry 'tags'" },
    }
    for _, case in ipairs(cases) do
      local view, err = views.normalize(case[1])
      assert.is_nil(view)
      assert.truthy(err:find(case[2], 1, true), err)
    end
  end)
end)

describe("rules.views: the views of the vault", function()
  it("makes a new view under views/ with its name from the title, lists it, and takes it back with its inverse", function()
    local root = make_vault()
    local entry = run(root, { op = "view_save", view = vim.tbl_extend("force", SEVERITY, { select = { families = { "DEP" } } }) })
    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("created", entry.outcome)
    assert.are.equal("by-severity", entry.id)
    local text = read_raw(root .. "/views/by-severity.md")
    assert.truthy(text:find("group_by: severity", 1, true))
    assert.truthy(text:find("created: 2026-01-01", 1, true))

    local doc = views_doc(root)
    assert.are.equal("rules.views", doc.kind)
    assert.are.equal(1, #doc.views)
    assert.are.equal("by-severity", doc.views[1].id)
    assert.are.same({ "DEP" }, doc.views[1].select.families)
    assert.are.equal(entry.etag_after, doc.views[1].etag)

    -- the same title again takes the next free name
    assert.are.equal("by-severity-2", run(root, { op = "view_save", view = SEVERITY }).id)

    local back = run(root, entry.inverse)
    assert.are.equal("deleted", back.outcome)
    assert.is_nil(read_raw(root .. "/views/by-severity.md"))
  end)

  it("replaces a view only on the version read, and its inverse brings the old one back", function()
    local root = make_vault()
    local made = run(root, { op = "view_save", view = SEVERITY })
    local changed = { title = "By family", display = "list", group_by = "family" }
    local stale = run(root, { op = "view_save", id = made.id, view = changed, if_match = "sha256:0000000000000000" })
    assert.is_false(stale.ok)
    assert.are.equal("conflict", stale.error.code)
    local none = run(root, { op = "view_save", id = made.id, view = changed })
    assert.are.equal("conflict", none.error.code)

    local entry = run(root, { op = "view_save", id = made.id, view = changed, if_match = made.etag_after })
    assert.are.equal("changed", entry.outcome)
    assert.are.equal("family", views_doc(root).views[1].group_by)
    local same = run(root, { op = "view_save", id = made.id, view = changed, if_match = entry.etag_after })
    assert.are.equal("unchanged", same.outcome)

    run(root, entry.inverse)
    local doc = views_doc(root)
    assert.are.equal("severity", doc.views[1].group_by)
    assert.are.equal("By severity", doc.views[1].title)
  end)

  it("deletes a view only with the version read, and a dry run writes nothing", function()
    local root = make_vault()
    local made = run(root, { op = "view_save", view = SEVERITY })
    local dry = run(root, { op = "view_save", view = { title = "Dry", display = "list", group_by = "family" } }, true)
    assert.are.equal("would_create", dry.outcome)
    assert.is_nil(read_raw(root .. "/views/dry.md"))

    local without = run(root, { op = "view_delete", id = made.id })
    assert.are.equal("invalid_argument", without.error.code)
    local stale = run(root, { op = "view_delete", id = made.id, if_match = "sha256:0000000000000000" })
    assert.are.equal("conflict", stale.error.code)
    assert.are.equal("not_found", run(root, { op = "view_delete", id = "nope", if_match = "x" }).error.code)

    local gone = run(root, { op = "view_delete", id = made.id, if_match = made.etag_after })
    assert.are.equal("deleted", gone.outcome)
    assert.are.equal(0, #views_doc(root).views)
    -- the inverse makes it again, with the same view
    run(root, gone.inverse)
    assert.are.equal("severity", views_doc(root).views[1].group_by)
  end)

  it("lists a file that is no view as a problem, and the others still", function()
    local root = make_vault()
    run(root, { op = "view_save", view = SEVERITY })
    write_raw(root .. "/views/broken.md", "---\ntitle: Broken\ndisplay: board\ngroup_by: severity\n---\n")
    write_raw(root .. "/views/Not-A-Slug.md", "---\ntitle: x\n---\n")
    local doc = views_doc(root)
    assert.are.equal(1, #doc.views)
    assert.are.equal(1, #doc.problems)
    assert.are.equal("broken", doc.problems[1].id)
    assert.are.equal("views/broken.md", doc.problems[1].file)
    assert.truthy(doc.problems[1].message:find("board", 1, true))
    assert.is_nil(doc.problems[1].message:find(root, 1, true))
  end)

  it("is a new state when a view changes, not before", function()
    local root = make_vault()
    local first = views_doc(root)
    assert.are.same({}, first.views)
    run(root, { op = "view_save", view = SEVERITY })
    local second = views_doc(root)
    assert.are_not.equal(first.rev, second.rev)
    assert.are.equal(second.rev, views_doc(root).rev)
  end)
end)
