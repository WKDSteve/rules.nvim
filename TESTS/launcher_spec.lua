-- TESTS/launcher_spec.lua -- the `rules` command itself (bin/rules, and bin/rules.cmd on Windows): it runs
-- scripts/rules.lua headless, hands its output and exit code through, and is never silent (no nvim on the PATH, or a
-- copy of the launcher away from its checkout: a message and exit 3). Starts `sh` / `cmd`: both are in
-- `guard_allow.spawn` of .testing.lua.

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))
local win = vim.fn.has("win32") == 1
local sep = win and ";" or ":"

---@param path_env string the PATH the launcher sees
---@param bin string the folder holding the launcher
---@param ... string arguments of `rules`
---@return vim.SystemCompleted
local function launch(path_env, bin, ...)
  -- resolved here: vim.system looks the program up in the PATH handed to the child, and a bare one has no sh
  local argv = win and { "cmd.exe", "/d", "/c", bin .. "/rules.cmd", ... } or { vim.fn.exepath("sh"), bin .. "/rules", ... }
  return vim.system(argv, { text = true, env = { PATH = path_env } }):wait(60000)
end

---@param r vim.SystemCompleted
---@param needle string
local function says(r, needle)
  assert.is_truthy((r.stderr or ""):find(needle, 1, true), "stderr: " .. (r.stderr or ""):sub(1, 300))
end

describe("the rules command", function()
  local bin = repo .. "/bin"
  local with_nvim = vim.fs.dirname(vim.v.progpath) .. sep .. (os.getenv("PATH") or "")

  it("is there for both shells", function()
    assert.is_truthy(vim.uv.fs_stat(bin .. "/rules"))
    assert.is_truthy(vim.uv.fs_stat(bin .. "/rules.cmd"))
  end)

  it("is executable in the repository, so a shell runs it by its name from the PATH", function()
    -- git keeps the mode, not the checkout on Windows (core.fileMode false): asked of git, it holds on every system
    local tree = vim.system({ "git", "-C", repo, "ls-files", "-s", "--", "bin/rules" }, { text = true }):wait(20000)
    assert.are.equal(0, tree.code, tree.stderr)
    assert.are.equal("100755", (tree.stdout or ""):match("^(%d+)"), tree.stdout)
  end)

  it("runs scripts/rules.lua and hands its usage and exit code through", function()
    -- an unknown command is wrong usage (exit 2) before lib.nvim is looked for, so the result does not hang on it
    local r = launch(with_nvim, bin, "no-such-command")
    assert.are.equal(2, r.code, r.stderr)
    says(r, "usage: rules.lua")
  end)

  it("says so, with exit code 3, when nvim is not on the PATH", function()
    local bare
    if win then
      bare = (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32"
    else
      -- a PATH with only the one external tool the script needs (`dirname`), so no nvim of the system is found
      bare = vim.fn.tempname()
      vim.fn.mkdir(bare, "p")
      assert(vim.uv.fs_symlink(vim.fn.exepath("dirname"), bare .. "/dirname"))
    end
    local r = launch(bare, bin, "no-such-command")
    if not win then
      vim.fn.delete(bare, "rf")
    end
    assert.are.equal(3, r.code, r.stderr)
    says(r, "nvim is not on the PATH")
  end)

  it("says so, with exit code 3, when it is copied away from its checkout", function()
    local away = vim.fn.tempname() .. "/bin"
    vim.fn.mkdir(away, "p")
    for _, name in ipairs({ "rules", "rules.cmd" }) do
      assert(vim.uv.fs_copyfile(bin .. "/" .. name, away .. "/" .. name))
    end
    if not win then
      vim.uv.fs_chmod(away .. "/rules", 493)
    end
    local r = launch(with_nvim, away, "no-such-command")
    assert.are.equal(3, r.code, r.stderr)
    says(r, "cannot find")
    vim.fn.delete(vim.fs.dirname(away), "rf")
  end)
end)
