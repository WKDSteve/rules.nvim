-- TESTS/git_files_spec.lua -- `rules.git_files`: what the files in `.git` answer without a git process (the top of the
-- work tree, the commit of HEAD, the upstream), and where they say `unsure` so the caller asks git as before.
--
-- The repositories are folders this spec writes by hand (HEAD, refs, packed-refs, config): no git runs. Every git
-- start would fail the spec (`vim.system` and `vim.fn.system` throw while it runs). What real git writes is covered by
-- `vault_behind_spec` and `vault_spec`, which compare against real repositories.
---@diagnostic disable: need-check-nil
local files = require("rules.git_files")

local SHA_A = string.rep("a", 40)
local SHA_B = string.rep("b", 40)

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return (path:gsub("\\", "/"))
end

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---A repository at `<base>/repo` on branch `main`.
---@param opts? { head?: string, refs?: table<string, string>, packed?: string, config?: string }
---@return string top
local function repo(opts)
  opts = opts or {}
  local top = tmp_dir() .. "/repo"
  write_raw(top .. "/.git/HEAD", opts.head or "ref: refs/heads/main\n")
  for ref, value in pairs(opts.refs or {}) do
    write_raw(top .. "/.git/" .. ref, value .. "\n")
  end
  if opts.packed then
    write_raw(top .. "/.git/packed-refs", opts.packed)
  end
  write_raw(top .. "/.git/config", opts.config or "[core]\n\tbare = false\n")
  vim.fn.mkdir(top .. "/sub/deeper", "p")
  return top
end

local TRACKING = table.concat({
  "[core]",
  "\trepositoryformatversion = 0",
  '[remote "origin"]',
  "\turl = https://example.invalid/vault.git",
  "\tfetch = +refs/heads/*:refs/remotes/origin/*",
  '[branch "main"]',
  "\tremote = origin",
  "\tmerge = refs/heads/main",
  "",
}, "\n")

describe("rules.git_files", function()
  local saved_system, saved_fn_system

  before_each(function()
    saved_system, saved_fn_system = vim.system, vim.fn.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv)
      error("git_files started a process: " .. table.concat(argv, " "))
    end
    vim.fn.system = function(argv)
      error("git_files started a process: " .. vim.inspect(argv))
    end
  end)

  after_each(function()
    vim.system, vim.fn.system = saved_system, saved_fn_system
  end)

  describe("find", function()
    it("finds the top of the work tree from a folder below it", function()
      local top = repo()
      local found = files.find(top .. "/sub/deeper")
      assert.are.equal(top, found.top)
      assert.are.equal(top .. "/.git", found.gitdir)
      assert.are.equal(top .. "/.git", found.commondir)
    end)

    it("is nil outside a repository", function()
      assert.is_nil(files.find(tmp_dir()))
    end)

    it("passes over a .git that is no repository, as git does", function()
      local top = repo()
      write_raw(top .. "/sub/.git", "not a gitdir line\n")
      assert.are.equal(top, files.find(top .. "/sub").top)
    end)

    it("follows the .git file of a linked worktree to its gitdir and its common dir", function()
      local main = repo({ refs = { ["refs/heads/main"] = SHA_A, ["refs/heads/feature"] = SHA_B } })
      local wt = tmp_dir() .. "/wt"
      local gitdir = main .. "/.git/worktrees/wt"
      write_raw(gitdir .. "/HEAD", "ref: refs/heads/feature\n")
      write_raw(gitdir .. "/commondir", "../..\n")
      write_raw(wt .. "/.git", "gitdir: " .. gitdir .. "\n")
      local found = files.find(wt)
      assert.are.equal(wt, found.top)
      assert.are.equal(gitdir, found.gitdir)
      assert.are.equal(gitdir .. "/../..", found.commondir)
      local head = files.head(wt)
      assert.are.equal(SHA_B, head.sha, "the branch of the worktree, from the refs of the main repository")
      assert.are.equal("feature", head.branch)
    end)
  end)

  describe("head", function()
    it("reads the commit of a branch from its loose ref", function()
      local top = repo({ refs = { ["refs/heads/main"] = SHA_A } })
      local head, unsure = files.head(top .. "/sub")
      assert.is_nil(unsure)
      assert.are.same({ sha = SHA_A, branch = "main" }, { sha = head.sha, branch = head.branch })
    end)

    it("reads packed-refs when there is no loose ref, and a loose ref wins over a packed one", function()
      local packed = "# pack-refs with: peeled fully-peeled sorted \n" .. SHA_B .. " refs/heads/main\n"
      assert.are.equal(SHA_B, files.head(repo({ packed = packed })).sha)
      assert.are.equal(SHA_A, files.head(repo({ packed = packed, refs = { ["refs/heads/main"] = SHA_A } })).sha)
    end)

    it("has no commit on an unborn branch, and is sure of it", function()
      local head, unsure = files.head(repo())
      assert.is_nil(unsure)
      assert.is_nil(head.sha)
    end)

    it("reads a detached HEAD", function()
      local head = files.head(repo({ head = SHA_A .. "\n" }))
      assert.are.equal(SHA_A, head.sha)
      assert.is_nil(head.branch)
    end)

    it("is unsure of a reftable repository and of a HEAD outside refs/heads", function()
      local reftable = repo({ head = "ref: refs/heads/.invalid\n" })
      write_raw(reftable .. "/.git/reftable/tables.list", "0x01.ref\n")
      local _, unsure = files.head(reftable)
      assert.is_true(unsure)
      _, unsure = files.head(repo({ head = "ref: refs/remotes/origin/main\n" }))
      assert.is_true(unsure)
    end)

    it("is unsure when GIT_DIR points git elsewhere: git would not read these files", function()
      local top = repo({ refs = { ["refs/heads/main"] = SHA_A } })
      local saved = vim.env.GIT_DIR
      vim.env.GIT_DIR = top .. "/.git"
      local head, unsure = files.head(top)
      local _, redirected = files.find(top)
      vim.env.GIT_DIR = saved
      assert.is_nil(head)
      assert.is_true(unsure)
      assert.is_true(redirected)
    end)

    it("is nil and sure outside a repository", function()
      local head, unsure = files.head(tmp_dir())
      assert.is_nil(head)
      assert.is_nil(unsure)
    end)
  end)

  describe("upstream", function()
    it("reads HEAD and its upstream through the default fetch refspec", function()
      local top = repo({
        config = TRACKING,
        refs = { ["refs/heads/main"] = SHA_A, ["refs/remotes/origin/main"] = SHA_B },
      })
      local pair, unsure = files.upstream(top .. "/sub")
      assert.is_nil(unsure)
      assert.are.same({ head = SHA_A, upstream = SHA_B }, pair)
    end)

    it("reads an upstream that is a local branch (remote = .)", function()
      local config = '[branch "main"]\n\tremote = .\n\tmerge = refs/heads/base\n'
      local top = repo({ config = config, refs = { ["refs/heads/main"] = SHA_A, ["refs/heads/base"] = SHA_A } })
      assert.are.same({ head = SHA_A, upstream = SHA_A }, files.upstream(top))
    end)

    it("is nil and sure when the upstream was never fetched, or HEAD is unborn or detached", function()
      for _, top in ipairs({
        repo({ config = TRACKING, refs = { ["refs/heads/main"] = SHA_A } }),
        repo({ config = TRACKING }),
        repo({ config = TRACKING, head = SHA_A .. "\n" }),
      }) do
        local pair, unsure = files.upstream(top)
        assert.is_nil(pair)
        assert.is_nil(unsure)
      end
    end)

    it("is unsure where git may read the config another way", function()
      local refs = { ["refs/heads/main"] = SHA_A, ["refs/remotes/origin/main"] = SHA_B }
      for what, config in pairs({
        include = TRACKING .. "[include]\n\tpath = more.cfg\n",
        refspec = (TRACKING:gsub("refs/remotes/origin/%*", "refs/remotes/mirror/*")),
        quoted = (TRACKING:gsub("merge = refs/heads/main", 'merge = "refs/heads/main"')),
        ["no upstream here (git may find one in the global config)"] = "[core]\n\tbare = false\n",
      }) do
        local pair, unsure = files.upstream(repo({ config = config, refs = refs }))
        assert.is_nil(pair, what)
        assert.is_true(unsure, what)
      end
    end)

    it("reads keys without case and the last value of a key, as git does", function()
      local config = TRACKING .. '[Branch "main"]\n\tMerge = refs/heads/other ; a comment\n'
      local top = repo({
        config = config,
        refs = { ["refs/heads/main"] = SHA_A, ["refs/remotes/origin/other"] = SHA_B },
      })
      assert.are.same({ head = SHA_A, upstream = SHA_B }, files.upstream(top))
    end)
  end)
end)
