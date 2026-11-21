---@module 'rules.git_files'
---@brief What the files in `.git` say without a git process: where the repository is, the commit of HEAD, the upstream.
---@description
--- `:RulesVault`, `:RulesVault create --git`, `:Rules new` and the acceptance of a review asked git small questions
--- whose answers sit in a few small files: is this folder a repository (and its top), which commit is HEAD, which
--- branch does HEAD track. A git start costs 50-150 ms on Windows, on the UI loop; reading the files costs nothing.
---
--- Only what the files answer the way git would is answered here. Anything else (a reftable repository, a config
--- that includes other files, a fetch refspec of its own, a quoted value) says `unsure`, and the caller asks git as
--- before; so does `GIT_DIR` (or another variable that points git elsewhere) in the environment.
---
--- Finding the repository is lib.nvim's (`lib.nvim.git.files.find`, the reader behind `git.current_ref_fast` and
--- `git.remote_url_fast`, task `lib.nvim/git-remote-url-und-branch-aus-git-dateien-lesen-statt-per`); lib.nvim reads
--- no commit of a ref nor an upstream, which this module adds. Candidates to move there.

local M = {}

---@param path string
---@return string|nil
local function read(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local ok, text = pcall(fd.read, fd, "*a")
  fd:close()
  if ok and type(text) == "string" then
    return text
  end
  return nil
end

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param p string
---@return boolean
local function is_absolute(p)
  return p:sub(1, 1) == "/" or p:match("^%a:[/\\]") ~= nil
end

---@param base string
---@param p string
---@return string
local function resolve(base, p)
  p = p:gsub("\\", "/")
  if is_absolute(p) then
    return p
  end
  return base .. "/" .. p
end

---@param s string|nil
---@return boolean
local function is_sha(s)
  return s ~= nil and (#s == 40 or #s == 64) and s:match("^%x+$") ~= nil
end

---@class Rules.GitFiles.Repo
---@field top string        the folder that holds `.git` (the top of the work tree), `/`-separated
---@field gitdir string     the repository's own directory (`.git`, or what a `.git` file names)
---@field commondir string  where refs, `packed-refs` and `config` live (the main `.git` of a linked worktree)

---The reader of an older lib.nvim that has no `lib.nvim.git.files` yet: the same walk.
---@param dir string
---@return Rules.GitFiles.Repo|nil
local function own_find(dir)
  dir = dir:gsub("\\", "/"):gsub("(.)/+$", "%1")
  while dir and dir ~= "" do
    local gitdir
    if read(dir .. "/.git/HEAD") then
      gitdir = dir .. "/.git"
    else
      local text = read(dir .. "/.git")
      local target = text and text:match("^gitdir:%s*(.-)%s*$")
      if target and target ~= "" then
        local named = resolve(dir, target)
        if read(named .. "/HEAD") then
          gitdir = named
        end
      end
    end
    if gitdir then
      local common = read(gitdir .. "/commondir")
      local commondir = common and trim(common) ~= "" and resolve(gitdir, trim(common)) or gitdir
      return { top = dir, gitdir = gitdir, commondir = commondir }
    end
    local parent = dir:match("^(.*)/[^/]*$")
    if parent == "" and dir:sub(1, 1) == "/" and dir ~= "/" then
      parent = "/"
    end
    if not parent or parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

---@return boolean
local function own_env_redirects()
  for _, name in ipairs({ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_CONFIG", "GIT_CONFIG_GLOBAL" }) do
    local v = vim.env[name]
    if v ~= nil and v ~= "" then
      return true
    end
  end
  return false
end

---The nearest repository at or above `dir`, as git finds it: a `.git` folder, or a `.git` file (`gitdir: <path>`, a
---linked worktree or a submodule) followed to its directory, `commondir` honoured. `nil` when there is none up to the
---root of the disk. The walk is lib.nvim's (`lib.nvim.git.files.find`, shared with `git.current_ref_fast`), with a
---copy of it for an older lib.nvim.
---
---`redirected` is true when the environment points git somewhere else (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG*`):
---git would not answer from these files then, so a caller that must answer as git does asks git.
---@param dir string
---@return Rules.GitFiles.Repo|nil repo
---@return boolean redirected
function M.find(dir)
  local ok, lib_files = pcall(require, "lib.nvim.git.files")
  if ok and type(lib_files) == "table" and type(lib_files.find) == "function" then
    return lib_files.find(dir), lib_files.env_redirects()
  end
  return own_find(dir), own_env_redirects()
end

---The refs that live in a worktree's own directory, not in the common one (git's `refs/worktree`, `refs/bisect`,
---`refs/rewritten` and the pseudo refs at the top).
---@param ref string
---@return boolean
local function per_worktree(ref)
  return not ref:find("/")
    or ref:match("^refs/worktree/") ~= nil
    or ref:match("^refs/bisect/") ~= nil
    or ref:match("^refs/rewritten/") ~= nil
end

---The commit a ref names: its loose file first (it wins over `packed-refs`, as in git), then `packed-refs`. A ref that
---names another ref (`ref: ...`) is followed, five steps at most.
---@param repo Rules.GitFiles.Repo
---@param ref string  e.g. `refs/heads/main`
---@return string|nil sha  nil: the ref does not exist (an unborn branch, an upstream never fetched)
---@return boolean|nil unsure  the files do not answer it the way git would
function M.ref_sha(repo, ref)
  for _ = 1, 5 do
    if ref:find("%.%.") or ref:find("[%z\r\n]") then
      return nil, true
    end
    local base = per_worktree(ref) and repo.gitdir or repo.commondir
    local loose = read(base .. "/" .. ref)
    if loose then
      local text = trim(loose)
      if is_sha(text) then
        return text:lower(), nil
      end
      local next_ref = text:match("^ref:%s*(%S+)$")
      if not next_ref then
        return nil, true
      end
      ref = next_ref
    else
      local packed = read(repo.commondir .. "/packed-refs")
      if packed then
        for line in packed:gmatch("[^\r\n]+") do
          local sha, name = line:match("^(%x+) (%S+)$")
          if name == ref and is_sha(sha) then
            return sha:lower(), nil
          end
        end
      end
      return nil, nil
    end
  end
  return nil, true
end

---@class Rules.GitFiles.Head
---@field sha string|nil     the commit of HEAD; nil on an unborn branch
---@field branch string|nil  the branch HEAD is on (`main`); nil when HEAD is detached
---@field repo Rules.GitFiles.Repo

---The commit HEAD is at, and the branch it is on.
---@param dir string  a folder in the work tree
---@return Rules.GitFiles.Head|nil head  nil: no repository, or `unsure`
---@return boolean|nil unsure  the files do not answer it the way git would (a reftable repository, a HEAD that names
---  something outside `refs/heads/`, a ref that is neither a commit nor a ref)
function M.head(dir)
  local repo, redirected = M.find(dir)
  if redirected then
    return nil, true
  end
  if not repo then
    return nil, nil
  end
  -- a reftable repository keeps a placeholder in HEAD and its refs in `reftable/`
  if read(repo.commondir .. "/reftable/tables.list") then
    return nil, true
  end
  local text = read(repo.gitdir .. "/HEAD")
  if not text then
    return nil, true
  end
  text = trim(text)
  if is_sha(text) then
    return { sha = text:lower(), repo = repo }, nil
  end
  local branch = text:match("^ref:%s*refs/heads/(%S+)$")
  if not branch or branch == ".invalid" then
    return nil, true
  end
  local sha, unsure = M.ref_sha(repo, "refs/heads/" .. branch)
  if unsure then
    return nil, true
  end
  return { sha = sha, branch = branch, repo = repo }, nil
end

---The keys of one `[section "sub"]` of a git config text, as git reads them: section names and keys without case,
---the subsection with it, the last value wins. `unsure` when the text could change the answer in a way this reader
---does not follow: an `include`/`includeIf`, a worktree config, a quoted or escaped value, a continued line.
---@param text string
---@param section string  lower case, e.g. `branch`
---@param sub string
---@return table<string, string> values  keys lower case
---@return boolean unsure
function M.config_section(text, section, sub)
  local lower = text:lower()
  if lower:find("%[%s*include") or lower:find("worktreeconfig") then
    return {}, true
  end
  local values, inside = {}, false
  for line in text:gmatch("[^\r\n]+") do
    local stripped = trim(line)
    if stripped:sub(1, 1) == "[" then
      local name, quoted = stripped:match('^%[%s*([%w%.%-]+)%s+"(.-)"%s*%]$')
      if name then
        inside = name:lower() == section and quoted == sub
      elseif stripped:match("^%[%s*[%w%.%-]+%s*%]$") then
        local dotted = stripped:match("^%[%s*([%w%-]+)%.") -- the old `[branch.main]` form: case-folded subsection
        inside = false
        if dotted then
          return {}, true
        end
      else
        return {}, true
      end
    elseif inside and stripped ~= "" and not stripped:match("^[#;]") then
      local key, value = stripped:match("^([%w%-]+)%s*=%s*(.-)$")
      if not key then
        return {}, true
      end
      value = value:gsub("%s+[#;].*$", "")
      if value:find('["\\]') then
        return {}, true
      end
      values[key:lower()] = trim(value)
    end
  end
  return values, false
end

---@class Rules.GitFiles.Upstream
---@field head string      the commit of HEAD
---@field upstream string  the commit of the branch HEAD tracks (`@{u}`), as the last fetch left it

---The commits of HEAD and of its upstream (`@{u}`): the branch in `branch.<name>.merge`, from the remote in
---`branch.<name>.remote` through the default fetch refspec (`refs/remotes/<remote>/<branch>`), or a local branch
---(`remote = .`).
---@param dir string
---@return Rules.GitFiles.Upstream|nil pair  nil: no repository, an unborn or detached HEAD, no upstream, an upstream
---  never fetched -- or `unsure`
---@return boolean|nil unsure  the files do not answer it the way git would (see `head`, `config_section`; also a
---  fetch refspec other than the default, and a branch without an upstream in this repository's config, which git
---  may still find in the global one)
function M.upstream(dir)
  local head, unsure = M.head(dir)
  if unsure then
    return nil, true
  end
  if not head or not head.sha or not head.branch then
    return nil, nil
  end
  local config = read(head.repo.commondir .. "/config")
  if not config then
    return nil, true
  end
  local branch, bad = M.config_section(config, "branch", head.branch)
  if bad or not branch.merge or not branch.remote then
    return nil, true
  end
  local merged = branch.merge:match("^refs/heads/(.+)$")
  if not merged then
    return nil, true
  end
  local ref
  if branch.remote == "." then
    ref = "refs/heads/" .. merged
  else
    local remote, rbad = M.config_section(config, "remote", branch.remote)
    if rbad or remote.fetch ~= ("+refs/heads/*:refs/remotes/%s/*"):format(branch.remote) then
      return nil, true
    end
    ref = ("refs/remotes/%s/%s"):format(branch.remote, merged)
  end
  local upstream, uns = M.ref_sha(head.repo, ref)
  if uns then
    return nil, true
  end
  if not upstream then
    return nil, nil
  end
  return { head = head.sha, upstream = upstream }, nil
end

return M
