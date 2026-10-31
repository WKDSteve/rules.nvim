-- TESTS/vault_ci_checkout_spec.lua -- the line-ending step of the CI workflow of a rules-vault
-- (templates/rules-vault-ci.yml) in a real checkout: a repository checked out by a git that turns LF into CRLF (a
-- Windows runner's default), with the `.gitattributes` the vault has. What the step looks at is the checkout, so what
-- the attributes say only counts when it takes effect. The shared code is TESTS/helpers/vault_ci.lua.
---@diagnostic disable: need-check-nil
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local ci = dofile(here .. "/helpers/vault_ci.lua")
local tmp_dir, write, run_template, red = ci.tmp_dir, ci.write, ci.run_template, ci.red
local LINE_ENDINGS = ci.LINE_ENDINGS

describe("the CI template of a rules-vault @spawn", function()
  describe("in a real checkout (core.autocrlf=true, as on a Windows runner)", function()
    if not ci.find_bash() or vim.fn.exepath("git") == "" then
      it("needs bash and git", function()
        pending("no bash to run the workflow's steps in, or no git to make a checkout with")
      end)
      return
    end

    ---@param cwd string
    ---@param ... string
    local function git(cwd, ...)
      local cmd = { "git", "-c", "user.name=spec", "-c", "user.email=spec@example.com", "-c", "commit.gpgsign=false", ... }
      local done = vim.system(cmd, { cwd = cwd, text = true }):wait(60000)
      assert(done.code == 0, table.concat(cmd, " ") .. ": " .. (done.stderr or ""))
    end

    ---A vault committed with `gitattributes` (nil: none), and a checkout of it that git converts to CRLF if it may.
    ---@param gitattributes string|nil
    ---@return string checkout
    local function checkout(gitattributes)
      local source = ci.make_vault()
      os.remove(source .. "/.gitattributes")
      if gitattributes then
        write(source .. "/.gitattributes", gitattributes)
      end
      git(source, "init", "-q")
      git(source, "-c", "core.autocrlf=false", "add", "-A")
      git(source, "-c", "core.autocrlf=false", "commit", "-q", "-m", "vault")
      local target = tmp_dir() .. "/vault"
      git(vim.fs.dirname(target), "-c", "core.autocrlf=true", "clone", "-q", "--no-hardlinks", source, target)
      return target
    end

    it("is green in every step when the .gitattributes keeps LF (`* text=auto eol=lf`)", function()
      local steps = run_template(checkout("* text=auto eol=lf\n"))
      assert.are.same({}, red(steps), vim.inspect(steps))
    end)

    -- the red cases are about the line-ending step only, which needs no nvim: it runs alone
    it("is red when the only eol=lf is a comment: the checkout is CRLF", function()
      local steps = run_template(checkout("# * text=auto eol=lf\n"), { only = LINE_ENDINGS })
      assert.are.same({ LINE_ENDINGS }, red(steps), vim.inspect(steps))
    end)

    it("is red when eol=lf is there for other files only (`*.png eol=lf`)", function()
      local steps = run_template(checkout("*.png eol=lf\n"), { only = LINE_ENDINGS })
      assert.are.same({ LINE_ENDINGS }, red(steps), vim.inspect(steps))
    end)

    it("is red without a .gitattributes", function()
      local steps = run_template(checkout(nil), { only = LINE_ENDINGS })
      assert.are.same({ LINE_ENDINGS }, red(steps), vim.inspect(steps))
    end)
  end)
end)
