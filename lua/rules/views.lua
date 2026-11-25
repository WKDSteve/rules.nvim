---@module 'rules.views'
---@brief The saved views of the rules, in the vault: one small Markdown file each at `<vault>/views/<slug>.md`.
---@description
--- A view is a selection (which rules), a grouping (by which field of `rules.groupings`, and for a matrix by a second
--- one) and a way to draw it; it holds no rule. It lives in the vault (not in a ruleset: a view may show the rules of
--- several), so it is the same on every machine. The engine reads the views with `rules.views` and writes them only
--- through the operations `view_save` and `view_delete`, on the version read (`if_match`), as tasks.nvim does for the
--- views of the tasks.
---
--- Frontmatter: `title`, `display`, `group_by`, `group_by2`, `collapsed` (the groups that are folded), `sel_families`,
--- `sel_severities`, `sel_statuses`, `sel_rulesets`, `sel_query`, `created`, `updated`.
---
--- A field to group by is one of `family`, `severity`, `status`, `waiver`, or the section of one layout:
--- `layout:<ruleset>:<output>` (the `ruleset` and `layout` of a `layout` field of `rules.groupings`). A view names a
--- layout by those words only; one that is gone is the client's to show, not a problem of the file.
---
--- Not its job: the documents (`rules.contract`), the request (`rules.ops`).

local fm = require("lib.nvim.markdown.frontmatter")
local view_file = require("lib.nvim.view_file")
local etag = require("lib.nvim.fs.etag")
local read = require("lib.nvim.fs.read")
local create_exclusive = require("lib.nvim.fs.create_exclusive")
local with_lock = require("lib.nvim.fs.with_lock")
local write_atomic = require("lib.nvim.fs.write.atomic")

local uv = vim.uv or vim.loop

local M = {}

---How a view is drawn.
M.DISPLAYS = { "columns", "list", "matrix" }

---The fields a view may group by besides the sections of a layout (`layout:<ruleset>:<output>`).
M.GROUP_FIELDS = { "family", "severity", "status", "waiver" }

---The selection of a view: its name and the frontmatter key.
---@type { name: string, key: string }[]
M.SELECT = {
  { name = "families", key = "sel_families" },
  { name = "severities", key = "sel_severities" },
  { name = "statuses", key = "sel_statuses" },
  { name = "rulesets", key = "sel_rulesets" },
}

---Most entries of a list of the selection, and of the folded groups; longest entry, title or query, in characters.
M.MAX_LIST = 100
M.MAX_ENTRY = 300
---Longest name of a view file, without `.md`.
M.MAX_SLUG = 80

local FIELD_SET = {}
for _, v in ipairs(M.GROUP_FIELDS) do
  FIELD_SET[v] = true
end

---@param s any
---@return boolean
local function has_control(s)
  return type(s) == "string" and s:find("[%c]") ~= nil
end

---Whether `field` is a field a view can group by: one of `GROUP_FIELDS`, or `layout:<ruleset>:<output>`.
---@param field any
---@return boolean
function M.is_field(field)
  if type(field) ~= "string" or has_control(field) or vim.fn.strchars(field) > M.MAX_ENTRY then
    return false
  end
  if FIELD_SET[field] then
    return true
  end
  local ruleset, output = field:match("^layout:([^:]+):(.+)$")
  return ruleset ~= nil and output ~= nil
end

---Whether `slug` is a name a view file can have: lowercase letters, digits and `-`, starting with a letter or digit.
---@param slug any
---@return boolean
function M.valid_slug(slug)
  return type(slug) == "string" and #slug <= M.MAX_SLUG and slug:match("^[a-z0-9][a-z0-9%-]*$") ~= nil
end

---The name a new view takes from its title: letters and digits, the rest a `-` (`view` when nothing is left).
---@param title string
---@return string
function M.slugify(title)
  local s = title:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  s = s:sub(1, M.MAX_SLUG - 4):gsub("%-+$", "")
  return s ~= "" and s or "view"
end

---@param root string
---@return string
function M.dir(root)
  return root .. "/views"
end

---@param root string
---@param slug string
---@return string
function M.path(root, slug)
  return M.dir(root) .. "/" .. slug .. ".md"
end

---@param path string
---@return string|nil kind  "file", "directory", "link", or nil when there is nothing
local function kind_of(path)
  local st = uv.fs_lstat(path)
  return st and st.type or nil
end

---Why the folder of the views must not be read or written, or nil: it is a symbolic link (or a junction), which could
---lead out of the vault.
---@param root string
---@return string|nil err
local function leaves(root)
  if kind_of(M.dir(root)) == "link" then
    return "views is a symbolic link: it is neither read nor written"
  end
  return nil
end

local shape = view_file.new({
  displays = M.DISPLAYS,
  is_field = M.is_field,
  fields_hint = table.concat(M.GROUP_FIELDS, ", ") .. ", or layout:<ruleset>:<output>",
  select = M.SELECT,
  allow_empty_word = true,
  max_list = M.MAX_LIST,
  max_entry = M.MAX_ENTRY,
})

---Check a view as a caller gives it and put it in the shape the file and the document have.
---@param def table  `{ title, display, group_by, group_by2?, collapsed?, select? }`
---@return table|nil view
---@return string|nil err
function M.normalize(def)
  return shape.normalize(def)
end

local pairs_of = shape.pairs_of

---A view file's text read as a view.
---@param text string
---@param slug string
---@return table|nil view
---@return string|nil problem
function M.parse_text(text, slug)
  local view, err = shape.parse_text(text, slug)
  if not view then
    return nil, err
  end
  view.id = slug
  view.etag = etag.of(text)
  return view, nil
end

---The view as a caller gives it (and takes it back): what a `view_save` carries, without what the file adds (`id`, the
---version, the dates). The inverse of a change is a `view_save` of this.
---@param view table
---@return table
function M.def_of(view)
  local select = {}
  for _, s in ipairs(M.SELECT) do
    select[s.name] = view.select[s.name]
  end
  select.query = view.select.query
  return {
    title = view.title,
    display = view.display,
    group_by = view.group_by,
    group_by2 = view.group_by2,
    collapsed = view.collapsed,
    select = select,
  }
end

---Every view of the vault, sorted by id, what could not be read (a file with a problem is no view but a line in the
---list of problems, and never hides the others), and the lines the `rev` of `rules.views` is made of.
---@param root string
---@return table[] views
---@return { id: string, file: string, message: string }[] problems
---@return string[] lines
function M.all(root)
  local views, problems, lines = {}, {}, {}
  local dir = M.dir(root)
  local escape = leaves(root)
  if escape then
    problems[1] = { id = "views", file = "views", message = escape }
    return views, problems, { "views\tlink" }
  end
  if kind_of(dir) ~= "directory" then
    return views, problems, lines
  end
  local names = vim.fn.readdir(dir)
  table.sort(names)
  for _, name in ipairs(names) do
    local slug = name:match("^(.+)%.md$")
    if slug and M.valid_slug(slug) then
      local path = dir .. "/" .. name
      local view, problem, tag
      if kind_of(path) == "link" then
        problem = "is a symbolic link: not read"
      else
        local text, rerr = read(path)
        if not text then
          problem = "cannot read: " .. tostring(rerr)
        else
          tag = etag.of(text)
          view, problem = M.parse_text(text, slug)
        end
      end
      lines[#lines + 1] = slug .. "\t" .. tostring(tag)
      if view then
        views[#views + 1] = view
      else
        problems[#problems + 1] = { id = slug, file = "views/" .. name, message = tostring(problem) }
      end
    end
  end
  return views, problems, lines
end

---@param id string
---@param expected string
---@param actual string
---@return nil
---@return string
---@return table
local function conflict(id, expected, actual)
  return nil,
    ("the view %s is not the version the change was made on (it is %s, the change was made on %s)"):format(
      id,
      tostring(actual),
      tostring(expected)
    ),
    { code = "conflict", id = id, expected = expected, actual = actual }
end

---Make or replace a view. Without `id` a new one is made, its name taken from the title (a free one: `-2`, `-3`);
---with `id` the view of that name is replaced, and `if_match` (the version the caller read) must still be the file's;
---an `id` of a file that is not there makes it.
---@param root string
---@param def table
---@param opts { id?: string, if_match?: string, today: string, dry_run?: boolean, _attempt?: integer }
---@return table|nil result  `{ id, created, changed, etag_before?, etag_after?, before? }`
---@return string|nil err
---@return table|nil info  `{ code = ... }`
function M.save(root, def, opts)
  local view, verr = M.normalize(def)
  if not view then
    return nil, verr, { code = "invalid_argument" }
  end
  local escape = leaves(root)
  if escape then
    return nil, escape, { code = "forbidden" }
  end
  if opts.id ~= nil and not M.valid_slug(opts.id) then
    return nil, "invalid view id: " .. tostring(opts.id), { code = "invalid_argument" }
  end
  local slug = opts.id
  if slug == nil then
    local base = M.slugify(view.title)
    local n = 1
    repeat
      slug = n == 1 and base or (base .. "-" .. n)
      n = n + 1
    until kind_of(M.path(root, slug)) == nil or n > 999
    if kind_of(M.path(root, slug)) ~= nil then
      return nil, "no free name for " .. base, { code = "invalid_argument" }
    end
  end
  local path = M.path(root, slug)
  local here = kind_of(path)
  if here == "link" then
    return nil, slug .. " is a symbolic link: it is not changed", { code = "forbidden" }
  end
  local result = { id = slug, created = here == nil, changed = true }

  if here == nil then
    if opts.if_match ~= nil then
      return conflict(slug, opts.if_match, "gone")
    end
    if opts.dry_run then
      return result, nil
    end
    local text, terr =
      fm.update_text("\n", pairs_of(view, { created = opts.today, updated = opts.today }, false), { create = true })
    if not text then
      return nil, "cannot build the view file: " .. tostring(terr)
    end
    vim.fn.mkdir(M.dir(root), "p")
    local ok, err = create_exclusive(path, text)
    if not ok then
      -- a name this call chose was taken between the look and the create: the next free one (a few times)
      if opts.id == nil and (opts._attempt or 0) < 5 and kind_of(path) ~= nil then
        return M.save(root, def, vim.tbl_extend("force", opts, { _attempt = (opts._attempt or 0) + 1 }))
      end
      return nil, "the view could not be made: " .. tostring(err), { code = kind_of(path) ~= nil and "conflict" or "io" }
    end
    result.etag_after = etag.of(text)
    return result, nil
  end

  -- an existing file: replaced under its lock, against the text read there
  local ok, werr, winfo = with_lock(path, function()
    local cur, rerr = read(path)
    if not cur then
      return nil, "cannot read the view " .. slug .. ": " .. tostring(rerr)
    end
    local tag = etag.of(cur)
    result.etag_before = tag
    -- a view that exists is replaced only on the version the caller read: a change made without it could undo another's
    if opts.if_match ~= tag then
      return conflict(slug, opts.if_match or "none", tag)
    end
    local before = M.parse_text(cur, slug)
    result.before = before and M.def_of(before) or nil
    local parsed = fm.parse(cur)
    local created = parsed and fm.get(parsed, "created") or opts.today
    local text, terr = fm.update_text(cur, pairs_of(view, { updated = opts.today, created = created }, true))
    if not text then
      return nil, "cannot build the view file: " .. tostring(terr)
    end
    result.etag_after = etag.of(text)
    result.changed = result.etag_after ~= tag
    if opts.dry_run or not result.changed then
      return true
    end
    local wrote, wr_err = write_atomic(path, text)
    if not wrote then
      return nil, "cannot write the view " .. slug .. ": " .. tostring(wr_err), { code = "io" }
    end
    return true
  end, { wait_ms = 2000 })
  if not ok then
    return nil, werr, winfo
  end
  return result, nil
end

---Delete a view, on the version read: `if_match` must still be the file's.
---@param root string
---@param id string
---@param opts { if_match: string, dry_run?: boolean }
---@return table|nil result  `{ id, etag_before, before? }`
---@return string|nil err
---@return table|nil info
function M.delete(root, id, opts)
  if not M.valid_slug(id) then
    return nil, "no such view: " .. tostring(id), { code = "not_found" }
  end
  local escape = leaves(root)
  if escape then
    return nil, escape, { code = "forbidden" }
  end
  local path = M.path(root, id)
  local here = kind_of(path)
  if here == "link" then
    return nil, id .. " is a symbolic link: it is not deleted", { code = "forbidden" }
  end
  if here ~= "file" then
    return nil, "no such view: " .. id, { code = "not_found" }
  end
  local result = { id = id }
  local ok, werr, winfo = with_lock(path, function()
    local cur, rerr = read(path)
    if not cur then
      return nil, "cannot read the view " .. id .. ": " .. tostring(rerr)
    end
    result.etag_before = etag.of(cur)
    if opts.if_match ~= result.etag_before then
      return conflict(id, opts.if_match, result.etag_before)
    end
    local before = M.parse_text(cur, id)
    result.before = before and M.def_of(before) or nil
    if opts.dry_run then
      return true
    end
    local removed, err = os.remove(path)
    if not removed then
      return nil, "cannot delete the view " .. id .. ": " .. tostring(err), { code = "io" }
    end
    return true
  end, { wait_ms = 2000 })
  if not ok then
    return nil, werr, winfo
  end
  return result, nil
end

return M
