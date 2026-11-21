---@module 'rules.vault'
---@brief The rules-vault: where it is, which rulesets it offers, whether it is a clean git repository.
---@description
--- A vault is a folder (its own repository) with the rulesets of a person under `rulesets/<name>/`. It is found, in this
--- order, from `vault` of the call, `setup({ vault = ... })`, `$RULES_VAULT`, then the `vault` of the project's
--- `.rules.json`. A path is never guessed: no vault is a normal state and answers with a message, not an error.
---
--- This module is the small public face of that (`rules.settings` does the work and ranks the places): the
--- `:RulesVault` command (`rules.ui.vault_cmd`) takes its `roots` from here.
---
---```lua
--- local vault = require("rules.vault")
--- local root, err = vault.root()          -- nil, "no vault is configured: ..." when there is none
--- local where = vault.source()            -- "setup" | "env" | "project" | "call" | nil
--- local folders = vault.rulesets()        -- { "<root>/rulesets/lua", "<root>/rulesets/native" }
---```
---
--- `opts.project` is the project root whose `.rules.json` may name a vault (default: the working directory, the root
--- `:Rules check` uses). The names of the rulesets in a document stay the folder names (`lua`, `native`), never these
--- paths (`rules-export/1`).
---
--- Reads only: `git_state` reads the top of the work tree from the `.git` files and runs `git status --porcelain` (no
--- network, no lock, a timeout), and says nothing when git is not installed; `git_state_async` is the same without
--- waiting (`:RulesVault`). `behind` is how far the vault lies behind its upstream, the question `rules.ops` asks
--- before a rule is made: from the `.git` files when HEAD and upstream are one commit, else `git rev-list --count
--- HEAD..@{u}` the same way, kept for that pair of commits.

local settings = require("rules.settings")

local M = {}

---The start of the message `root` gives when nothing names a vault (a normal state, unlike a vault that is named but
---unusable): a front end that tells the two apart tests for it with `is_none`.
M.NONE = "no vault is configured"

---Whether a message of `root` says that no vault is configured at all.
---@param message string|nil
---@return boolean
function M.is_none(message)
  return type(message) == "string" and message:sub(1, #M.NONE) == M.NONE
end

---@class Rules.Vault.Opts
---@field project? string  the root being checked (default: the working directory)
---@field vault? string    a vault to use instead of the configured one (the `call` layer)

---@param opts Rules.Vault.Opts|nil
---@return Rules.Settings
local function resolve(opts)
  opts = opts or {}
  -- the vault itself is the subject: a vault that cannot be used is a problem here, whatever else names the rulesets
  return settings.resolve({ project = opts.project or vim.fn.getcwd(), vault = opts.vault, need_vault = true })
end

---The vault folder, or `nil` and the reason: nothing is configured (a normal state), what is configured is not a folder,
---a file that names the vault cannot be used, or the vault's own `.rules.json` cannot be used (its list of rulesets would
---be guessed, so the vault is refused instead).
---@param opts Rules.Vault.Opts|nil
---@return string|nil root  absolute, `/`-separated
---@return string|nil message
function M.root(opts)
  local res = resolve(opts)
  if res.vault and res.vault.exists then
    local broken = settings.vault_error_text(res, false)
    if broken then
      return nil, broken
    end
    return res.vault.root, nil
  end
  local problem = settings.error_text(res, false)
  if problem then
    return nil, problem
  end
  return nil, M.NONE .. ": " .. settings.NO_VAULT_HINT
end

---Where the vault was named: `"call"`, `"setup"`, `"env"` ($RULES_VAULT) or `"project"`; `nil` without a vault. The second
---value is the problem of the vault when it has one (the same text `root` gives), `nil` otherwise.
---@param opts Rules.Vault.Opts|nil
---@return "call"|"setup"|"env"|"project"|nil
---@return string|nil problem
function M.source(opts)
  local res = resolve(opts)
  return res.vault and res.vault.source or nil, settings.vault_error_text(res, false)
end

---The rulesets the vault offers, as folders: the list in its own `.rules.json` when it has one, otherwise every folder
---under `<vault>/rulesets/` (sorted by name). Empty without a vault, and empty with the problem as the second value when the
---vault cannot be used (a `.rules.json` that is broken, an entry of its list that is refused): never the folders that
---the file may have meant to leave out.
---@param opts Rules.Vault.Opts|nil
---@return string[]
---@return string|nil problem
function M.rulesets(opts)
  local res = resolve(opts)
  local broken = settings.vault_error_text(res, false)
  if broken then
    return {}, broken
  end
  if res.vault and res.vault.exists then
    return vim.deepcopy(res.vault.loaded or res.vault.rulesets), nil
  end
  return {}, nil
end

---@class Rules.Vault.GitState
---@field repo boolean      the vault is the top of a git work tree
---@field inside string|nil the top of the work tree the vault lies in, when it is not its own
---@field clean boolean|nil nothing to commit (untracked files count); nil when git could not tell
---@field changes integer   how many paths `git status` lists
---@field error string|nil  why git could not tell (a timeout, a failure)

---@param a string
---@param b string
---@return boolean
local function same_folder(a, b)
  return require("lib.nvim.fs.same_path")(a, b, { realpath = true })
end

---The git options of the read-only questions: no lock (`--no-optional-locks`), no lazy fetch, five seconds at most.
---@param root string
---@return table
local function status_opts(root)
  return { dir = root, timeout_ms = 5000, read_only = true, no_lazy_fetch = true }
end

---What the files say before `git status` runs: whether git is there and where the work tree of `root` has its top.
---`final` is set when no git process is needed for the answer (git not installed: `nil`; no repository above `root`).
---@param root string
---@return Rules.Vault.GitState|nil state
---@return boolean final
local function git_frame(root)
  if vim.fn.executable("git") ~= 1 then
    return nil, true
  end
  -- the top of the work tree from the `.git` files (rules.git_files), not from `git rev-parse --show-toplevel`: one
  -- git start less on the UI loop, the same answer
  local repo, redirected = require("rules.git_files").find(root)
  local top = repo and repo.top
  if redirected then
    -- GIT_DIR and the like point git elsewhere: only git knows its answer (rare, and asked as before)
    local res = require("lib.nvim.git").run({ "rev-parse", "--show-toplevel" }, status_opts(root))
    if res.timed_out then
      return { repo = false, changes = 0, error = "git did not answer within 5 seconds" }, true
    end
    top = res.code == 0 and vim.trim(res.stdout or "") or nil
  end
  if not top then
    return { repo = false, changes = 0 }, true
  end
  local state = { repo = same_folder(top, root), changes = 0 }
  if not state.repo then
    state.inside = top
  end
  return state, false
end

---Put the answer of `git status --porcelain` into `state`.
---@param state Rules.Vault.GitState
---@param status Lib.Git.RunResult
---@return Rules.Vault.GitState
local function settle_status(state, status)
  if status.timed_out or status.code ~= 0 then
    state.error = status.timed_out and "git status did not answer within 5 seconds"
      or vim.trim(status.stderr or "git status failed")
    return state
  end
  local count = 0
  for line in (status.stdout or ""):gmatch("[^\r\n]+") do
    if line ~= "" then
      count = count + 1
    end
  end
  state.changes, state.clean = count, count == 0
  return state
end

---Whether `root` is a git repository and has nothing to commit. Read only: the top of the work tree comes from the
---`.git` files, then one `git status --porcelain` with `--no-optional-locks` (the index is not touched), no network,
---five seconds at most. Waits for git: a front end on the UI loop takes `git_state_async`.
---@param root string
---@return Rules.Vault.GitState|nil state  `nil` when git is not installed: nothing to say
function M.git_state(root)
  local state, final = git_frame(root)
  if final or not state then
    return state
  end
  return settle_status(state, require("lib.nvim.git").run({ "status", "--porcelain" }, status_opts(root)))
end

---`git_state` without waiting: `on_done` gets the same answer. When no git process is needed (git not installed, no
---repository above `root`) it is called at once, before this returns, and the handle is `nil`; otherwise from the
---callback of `git status` (`vim.schedule`d, so it may touch the editor), exactly once, also when the start fails.
---@param root string
---@param on_done fun(state: Rules.Vault.GitState|nil)
---@return { stop: fun() }|nil handle  stops the running `git status`; `on_done` is then not called
function M.git_state_async(root, on_done)
  local state, final = git_frame(root)
  if final or not state then
    on_done(state)
    return nil
  end
  local stopped = false
  local ok, job = pcall(require("lib.nvim.git").run_async, { "status", "--porcelain" }, status_opts(root), function(res)
    if not stopped then
      on_done(settle_status(state, res))
    end
  end)
  if not ok then
    -- a start that throws still answers once, on a later tick like every other answer
    vim.schedule(function()
      if not stopped then
        on_done(settle_status(state, { code = -1, stdout = "", stderr = tostring(job) }))
      end
    end)
    job = nil
  end
  return {
    stop = function()
      stopped = true
      if job then
        pcall(job.stop)
      end
    end,
  }
end

---How long `behind` waits for git: it reads the local refs only, so this is a generous bound, not a typical time.
M.BEHIND_TIMEOUT_MS = 3000

---Counts of `git rev-list --count A..B` by `"<A>..<B>"`: the count of two commits never changes. Emptied when it grows
---past 64 pairs (a long session with many fetches).
---@type table<string, integer>
local behind_cache = {}
local behind_cache_size = 0

---How many commits the upstream of the repository `root` lies in has that `HEAD` has not (`git rev-list --count
---HEAD..@{u}`): what a `git pull` would bring. It knows only what the last `git fetch` brought home: no network, no
---fetch, never a pull, no lock (`--no-optional-locks`), `BEHIND_TIMEOUT_MS` at most. Not `git_state`: that one runs
---`git status`, which the creation of a rule does not need to wait for.
---
---`nil` is "nothing to say" and covers git not installed, not a repository, no commit yet, no upstream, a timeout
---and anything git answers that is not a number: a warning that cannot be given is silence, never an error.
---
---The `.git` files answer first (rules.git_files): HEAD and its upstream at the same commit is 0 without git, and a
---count git gave is kept for that pair of commits (the count of two commits never changes, so the cache needs no
---invalidation; a commit, a pull or a fetch is a new pair). Only a new pair, or files git reads in a way the reader does
---not follow, start `git rev-list`.
---@param root string
---@return integer|nil behind  commits to pull (0: up to date)
function M.behind(root)
  if vim.fn.executable("git") ~= 1 then
    return nil
  end
  local pair, unsure = require("rules.git_files").upstream(root)
  if not pair and not unsure then
    -- no repository, an unborn or detached HEAD, no upstream fetched: what git would fail on too
    return nil
  end
  local key = pair and (pair.head .. ".." .. pair.upstream) or nil
  if pair and pair.head == pair.upstream then
    return 0
  end
  if key and behind_cache[key] then
    return behind_cache[key]
  end
  local done = require("lib.nvim.git").run(
    { "rev-list", "--count", "HEAD..@{u}" },
    { dir = root, timeout_ms = M.BEHIND_TIMEOUT_MS, read_only = true, no_lazy_fetch = true }
  )
  if done.timed_out or done.code ~= 0 then
    return nil
  end
  local count = tonumber(vim.trim(done.stdout or ""))
  if key and count then
    behind_cache_size = behind_cache_size + 1
    if behind_cache_size > 64 then
      behind_cache, behind_cache_size = {}, 1
    end
    behind_cache[key] = count
  end
  return count
end

return M
