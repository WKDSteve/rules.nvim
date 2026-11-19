-- TESTS/sheets/_bindings.lua -- the setup of the binding sheets (rules-bindings-*.sheet.lua). Not a sheet
-- (`testing.sheet` only reads *.sheet.lua); the first step of such a sheet runs it with `dofile`, the child's cwd is
-- the project root. The directory is in the spec's @cache-inputs.
--
-- Covers the rules.nvim items of the bindings runtime checklist of the nvim config
-- (docs/ROADMAP/Final_Checks/BINDINGS-RUNTIME-CHECKLIST.md, sections ":Rules" and ":RulesVault"): every command is
-- typed as a person types it, and the sheet reads what it did -- the message it gave, the file it wrote, the window,
-- the quickfix list, the register.
--
-- The configuration mirrors the one of the nvim config (lua/plugins/personal/specs/inspect.lua): `rulesets` is the
-- `lua` ruleset of the rules vault, `vault` is the vault ($RULES_VAULT there), the three gates of the config. The vault
-- is a fixture in a temp folder, never the real one: two rulesets, `lua` (family DEP: DEP-01 with a grep check,
-- DEP-02 manual, DEP-03 retired for DEP-02; one layout) and `native` (family ERR), plus a project folder with one file
-- the check of DEP-01 flags. The child's working directory is that project.
--
-- What stays a stand-in: the clipboard (`g:clipboard` is a provider that records into `_G.clip`, so the `+` register
-- works as on a desktop) and pickers.nvim (`pickers.command` and `pickers.engines` record what `find`/`grep` hand
-- over into `_G.picked`; the real pickers are the business of pickers.nvim's sheets). The messages are the real
-- toasts of lib.nvim; `_G.said(pattern)` reads their history (source "rules").

-- luacheck: globals vim

vim.opt.shortmess:append("I")
vim.o.swapfile = false
vim.o.cmdheight = 2
vim.g.mapleader = " "

local tmp = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
tmp = vim.fs.normalize(vim.uv.fs_realpath(tmp) or tmp)

---@param path string
---@param lines string[]
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
end

---@param id string
---@param severity string
---@param title string
---@param block? string[]
---@return string[]
local function rule(id, severity, title, block)
  local out = { "---", "id: " .. id, "severity: " .. severity, "family: " .. id:match("^(%a+)%-"), "---", "" }
  out[#out + 1] = "#### `" .. id .. "` — " .. title
  out[#out + 1] = ""
  if block then
    out[#out + 1] = "```rule"
    vim.list_extend(out, block)
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  out[#out + 1] = "Text of " .. id .. "."
  return out
end

local vault = tmp .. "/rules-vault"
local lua = vault .. "/rulesets/lua"
local native = vault .. "/rulesets/native"
write(
  lua .. "/_rules/DEP/DEP-01.md",
  rule("DEP-01", "recommended", "No FIXME left", {
    'check = { type = "grep", pattern = "FIXME" },',
  })
)
write(lua .. "/_rules/DEP/DEP-02.md", rule("DEP-02", "critical", "Pin every dependency"))
write(lua .. "/_retired/DEP/DEP-03.md", {
  "---",
  "id: DEP-03",
  "severity: nice-to-have",
  "family: DEP",
  "retired: 2026-01-01",
  "replaced_by: DEP-02",
  "reason: superseded",
  "---",
  "",
  "#### `DEP-03` — old",
})
write(lua .. "/_layouts/Dependencies.md", {
  "---",
  "kind: layout",
  "output: Dependencies.md",
  "---",
  "# Dependencies",
  "",
  "## Core",
  "",
  "{{rule DEP-01}}",
  "",
  "## Extra",
  "",
  "{{rule DEP-02}}",
})
write(native .. "/_rules/ERR/ERR-100.md", rule("ERR-100", "nice-to-have", "Errors name the file"))

local project = tmp .. "/project"
write(project .. "/main.lua", { "local x = 1 -- FIXME: name it", "return x" })
write(project .. "/notes.md", { "# Notes", "" })

_G.fx = { tmp = tmp, vault = vault, lua = lua, native = native, project = project }

-- the clipboard: a provider that records, so `+` works as with a real one
_G.clip = {}
vim.g.clipboard = {
  name = "sheet",
  copy = {
    ["+"] = function(lines)
      _G.clip[#_G.clip + 1] = table.concat(lines, "\n")
    end,
    ["*"] = function(lines)
      _G.clip[#_G.clip + 1] = table.concat(lines, "\n")
    end,
  },
  paste = {
    ["+"] = function()
      return vim.split(_G.clip[#_G.clip] or "", "\n"), "v"
    end,
    ["*"] = function()
      return vim.split(_G.clip[#_G.clip] or "", "\n"), "v"
    end,
  },
}

-- pickers.nvim: what `:RulesVault find|grep` hand over
_G.picked = {}
package.loaded["pickers.command"] = {
  dispatch = function(action, source)
    _G.picked[#_G.picked + 1] = { action = action, source = source }
  end,
}
package.loaded["pickers.engines"] = {
  load = function()
    return { name = "recorder" }
  end,
}

vim.cmd.cd(project)
-- `_G.fx_setup` (set by the step before the `dofile`): what a feature sheet adds to the setup, `agent` for instance
require("rules").setup(vim.tbl_deep_extend("force", {
  rulesets = { lua },
  vault = vault,
  gates = {
    new_project = { "NEW" },
    release = { "REL" },
    review = { "DEP" },
  },
}, _G.fx_setup or {}))

local popup = require("lib.nvim.notify.popup")

---The messages of rules.nvim since the last `said`, joined.
---@return string
function _G.text()
  local got = {}
  for _, m in ipairs(popup.history("rules")) do
    got[#got + 1] = m.message
  end
  return table.concat(got, "\n")
end

---Whether a message of rules.nvim matches `pattern` (a Lua pattern, `plain` for a plain find). The history is cleared
---after it, so the next step reads only what its own command said.
---@param pattern string
---@param plain? boolean
---@return boolean
function _G.said(pattern, plain)
  local all = _G.text()
  if all:find(pattern, 1, plain) then
    popup.clear("rules")
    return true
  end
  error(("no message %q among %s"):format(pattern, vim.inspect(all)), 0)
end

---Read a file whole, nil when there is none.
---@param path string
---@return string|nil
function _G.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

---The real path, `/`-separated (macOS: /var is /private/var; Windows: 8.3 names).
---@param path string
---@return string
function _G.real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

---The real path of the current buffer, `/`-separated (macOS: /var is /private/var).
---@return string
function _G.bufpath()
  local name = vim.api.nvim_buf_get_name(0)
  return vim.fs.normalize(vim.uv.fs_realpath(name) or name)
end

---Whether the focus is in a floating window: the button dialog of a question has it, a toast never takes it. A
---sheet types its answer only then, so the key cannot land in the buffer behind.
---@return boolean
function _G.dialog()
  return vim.api.nvim_win_get_config(0).relative ~= ""
end

---Run git in `dir` for the fixture (no signing, a fixed author); errors when git fails. A
---start from this file is the sheet's preparation for `testing perf`, never the plugin's.
---@param dir string
---@param args string[]
---@return string stdout
function _G.git(dir, args)
  local argv = {
    "git",
    "-C",
    dir,
    "-c",
    "commit.gpgsign=false",
    "-c",
    "tag.gpgsign=false",
    "-c",
    "user.name=sheet",
    "-c",
    "user.email=sheet@example.test",
    "-c",
    "init.defaultBranch=main",
  }
  vim.list_extend(argv, args)
  local done = vim.system(argv, { text = true }):wait(30000)
  assert(done.code == 0, ("git %s: %s"):format(table.concat(args, " "), done.stderr or ""))
  return done.stdout or ""
end

---The lines of the current buffer, joined.
---@return string
function _G.buftext()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

---The texts of the quickfix list, joined.
---@return string
function _G.qftext()
  local out = {}
  for _, item in ipairs(vim.fn.getqflist()) do
    out[#out + 1] = item.text
  end
  return table.concat(out, "\n")
end

return {}
