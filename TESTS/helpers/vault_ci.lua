-- TESTS/helpers/vault_ci.lua -- what the three vault_ci spec files share: the CI workflow of a rules-vault
-- (templates/rules-vault-ci.yml), its `run:` blocks taken out of the file and run with bash against small vaults.
--
-- The `run:` blocks are run in the folder of a fixture vault, with `nvim` and `.deps/rules.nvim` pointing at this
-- editor and this plugin: what is proved is the text of the template, not a copy of it.
--
-- Not a spec (no `_spec.lua`): the spec files load it with `dofile` (TESTS/ is not on the package path). The cases
-- are spread over three files because each `run_template` starts bash and up to four nvim; in one file they did not
-- fit the 60 s budget of a spec file on a loaded machine.
local catalog = require("rules.engine.catalog")

local M = {}

---@return string
function M.tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return (path:gsub("\\", "/"))
end

---@param path string
---@param text string
function M.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string|nil
function M.read(path)
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

local plugin_root = vim.fs.dirname(
  vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1])))
)
local lib_marker = assert(vim.api.nvim_get_runtime_file("lua/lib/nvim", false)[1], "lib.nvim is not on the runtimepath")
local lib_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(lib_marker)))
M.TEMPLATE = plugin_root .. "/templates/rules-vault-ci.yml"

M.LINE_ENDINGS = "The checked-out rule files have LF line endings (no CR)"
M.DOCUMENTS = "The reading documents are up to date (catalog --check, every ruleset)"
M.LOADS = "Every ruleset loads without errors (duplicate id, invalid severity)"
M.ROUND_TRIP = "Writing keeps the rule files byte for byte (round trip)"

---The bash the workflow runs in: the bash of Git on Windows (the first `bash` there may be the one of WSL), else `bash`.
---@return string|nil
function M.find_bash()
  if vim.fn.has("win32") ~= 1 then
    local found = vim.fn.exepath("bash")
    return found ~= "" and found or nil
  end
  local git = vim.fn.exepath("git")
  if git == "" then
    return nil
  end
  local top = vim.fs.dirname(vim.fs.normalize(git))
  for _ = 1, 3 do
    top = vim.fs.dirname(top)
    for _, rel in ipairs({ "/bin/bash.exe", "/usr/bin/bash.exe" }) do
      if (vim.uv or vim.loop).fs_stat(top .. rel) then
        return top .. rel
      end
    end
  end
  return nil
end

---The steps of the template that run a script: `{ name, script }`, in the order of the file.
---@param template string
---@return { name: string, script: string }[]
function M.steps_of(template)
  local out, name = {}, nil
  local lines = vim.split(template, "\n", { plain = true })
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local step = line:match("^      %- name: (.+)$")
    if step then
      name = step
    elseif line:match("^      %- uses:") then
      name = nil
    end
    if line:match("^        run: |%s*$") then
      local body = {}
      i = i + 1
      while i <= #lines and (lines[i] == "" or lines[i]:match("^          ")) do
        body[#body + 1] = lines[i]:sub(11)
        i = i + 1
      end
      out[#out + 1] = { name = name or "?", script = table.concat(body, "\n") .. "\n" }
    else
      i = i + 1
    end
  end
  return out
end

---@param script string
---@return string
local function for_here(script)
  local nvim = "'" .. vim.fs.normalize(vim.v.progpath) .. "' --headless"
  script = script:gsub("nvim %-%-headless", function()
    return nvim
  end)
  script = script:gsub("%.deps/rules%.nvim/", function()
    return "'" .. plugin_root .. "'/"
  end)
  return script
end

---@class VaultCiStep
---@field name string
---@field code integer
---@field out string

---@class VaultCiRunOpts
---@field template? string  the text of the workflow (default: the template of this plugin)
---@field only? string      the name of the one step to run (the line-ending step needs no nvim: a case about it alone
---                         spares the three steps that start one)

---Run the steps of the template in `vault`, each on its own (the CI stops at the first red step; here every step is
---asked, to see which ones turn red).
---@param vault string
---@param opts? VaultCiRunOpts
---@return VaultCiStep[] steps
---@return table<string, VaultCiStep> by_name
function M.run_template(vault, opts)
  opts = opts or {}
  local bash = assert(M.find_bash(), "no bash")
  local steps, by_name = {}, {}
  local all = M.steps_of(opts.template or assert(M.read(M.TEMPLATE)))
  for _, step in ipairs(all) do
    if not opts.only or step.name == opts.only then
      local done = vim
        .system({ bash, "-c", for_here(step.script) }, { cwd = vault, text = true, env = { LIB_NVIM_DIR = lib_dir } })
        :wait(120000)
      local result = { name = step.name, code = done.code, out = (done.stdout or "") .. (done.stderr or "") }
      steps[#steps + 1] = result
      by_name[step.name] = result
    end
  end
  assert(#steps > 0, "no step of the template is named " .. tostring(opts.only))
  return steps, by_name
end

---@param steps VaultCiStep[]
---@return string[]
function M.red(steps)
  local out = {}
  for _, step in ipairs(steps) do
    if step.code ~= 0 then
      out[#out + 1] = step.name
    end
  end
  return out
end

---@param id string
---@param severity? string
---@return string
function M.rule_text(id, severity)
  return doc({
    "---",
    "id: " .. id,
    "severity: " .. (severity or "critical"),
    "family: " .. id:match("^(%u+)"),
    "---",
    "",
    "#### `" .. id .. "`",
    "",
    "The text of " .. id .. ".",
  })
end

---A ruleset of one family with its layout and the document made from it.
---@param root string  the vault
---@param name string
---@param family string
---@param ids string[]
local function ruleset(root, name, family, ids)
  local dir = root .. "/rulesets/" .. name
  local layout = { "---", "kind: layout", "output: " .. family .. ".md", "---", "# " .. family, "" }
  for _, id in ipairs(ids) do
    M.write(("%s/_rules/%s/%s.md"):format(dir, family, id), M.rule_text(id))
    layout[#layout + 1] = "{{rule " .. id .. "}}"
    layout[#layout + 1] = ""
  end
  M.write(dir .. "/_layouts/" .. family .. ".md", doc(layout))
  local results, load_errors = catalog.build(dir)
  assert(#load_errors == 0, table.concat(load_errors, "; "))
  assert(results[1] and results[1].status == "written", "the document of " .. name .. " is made")
end

---A vault of two rulesets (as the real one is arranged), in good order.
---@return string root
function M.make_vault()
  local root = M.tmp_dir()
  M.write(root .. "/.gitattributes", "* text=auto eol=lf\n")
  M.write(root .. "/.rules.json", '{ "rulesets": ["rulesets/lua", "rulesets/native"], "gates": {} }\n')
  ruleset(root, "lua", "DEP", { "DEP-01", "DEP-02" })
  ruleset(root, "native", "NAT", { "NAT-01" })
  return root
end

return M
