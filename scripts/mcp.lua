-- scripts/mcp.lua -- the read-only MCP server of rules.nvim (stdio), for Claude Code and other clients.
--
--   nvim --headless -u NONE -l scripts/mcp.lua [--ruleset=<path>]... [--vault=<dir>] [--project=<dir>] [--trust=<dir>]...
--
-- The options mean what they mean for scripts/rules.lua; unset ones come from $RULES_RULESETS, $RULES_GATES,
-- $RULES_VAULT, $RULES_PROJECT and $RULES_TRUST. An MCP client starts this as a subprocess and speaks JSON-RPC on its
-- stdin/stdout; run by hand it waits for a line. The tools are `rules.mcp`. lib.nvim is found through $LIB_NVIM_DIR,
-- $LIB_NVIM_PATH, $REPOS_DIR/lib.nvim, .deps/lib.nvim, a sibling checkout, then lazy.nvim's data folder.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))
vim.opt.rtp:prepend(vim.fn.escape(plugin_root, ","))

---@param dir string|nil
---@return boolean
local function has_lib(dir)
  return dir ~= nil and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib/nvim") == 1
end

local repos = vim.env.REPOS_DIR
local lib
for _, dir in ipairs({
  vim.env.LIB_NVIM_DIR or "",
  vim.env.LIB_NVIM_PATH or "",
  (repos and repos ~= "") and (repos .. "/lib.nvim") or "",
  plugin_root .. "/.deps/lib.nvim",
  vim.fs.dirname(plugin_root) .. "/lib.nvim",
  vim.fn.stdpath("data") .. "/lazy/lib.nvim",
}) do
  if has_lib(dir) then
    lib = dir
    break
  end
end
if not lib then
  io.stderr:write("error: lib.nvim not found (set LIB_NVIM_DIR, or REPOS_DIR with a lib.nvim checkout)\n")
  os.exit(2)
end
vim.opt.rtp:append(vim.fn.escape(lib, ","))

local opts = require("rules.env").opts()
local rulesets, trust = {}, {}
for i = 1, #(_G.arg or {}) do
  local a = _G.arg[i]
  local key, value = a:match("^%-%-([%a]+)=(.+)$")
  if key == "ruleset" then
    rulesets[#rulesets + 1] = value
  elseif key == "trust" then
    trust[#trust + 1] = value
  elseif key == "vault" or key == "project" then
    opts[key] = value
  else
    io.stderr:write(
      ("error: unknown argument %s (usage: scripts/mcp.lua [--ruleset=P]... [--vault=D] [--project=D] [--trust=D]...)\n"):format(
        a
      )
    )
    os.exit(2)
  end
end
if #rulesets > 0 then
  opts.rulesets = rulesets
end
if #trust > 0 then
  opts.trust = trust
end

os.exit(require("rules.mcp").server(opts):serve())
