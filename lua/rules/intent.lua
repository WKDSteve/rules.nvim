---@module 'rules.intent'
---@brief Accepts the intents `rules.show` and `rules.new` of `wkd-intent/1` (a finding of testing.nvim becomes a rule).
---@description
--- An intent is **untrusted input**: it is pasted or piped in from another app, so this module checks it before it
--- touches the engine (size, schema, action, data class, no path of another machine, field lengths) and then maps
--- it to the engine's own doors, nothing else:
---
---  - `rules.show` -> `rules.api` method `rule` for `target.id` (or `finding.rule`).
---  - `rules.new`  -> `rules.ops` operation `new` with the title of the finding and a short text that carries the
---    **evidence as a reference** (`file:line` and `repo@sha`), never the excerpt: evidence files of a ruleset
---    describe, they are not copied into the rule. Saving needs a confirmation; without it the run is a dry run
---    (`dry_run = true`, the outcome says `would_create`).
---
--- The family is a proposal: `opts.family` first, then the family of `target.id`/`finding.rule`. An unknown or
--- misspelled family is refused by the ops door (`Rules.Ops.family_error`), a class other than `public`/`internal`
--- is refused here.
---
--- Mode `ai-draft` (a model words the body of the rule): the model call is not here -- `rules.agent.draft` makes
--- it and hands the checked body (`engine/agent/draft`) back as `opts.body`. Without a body (a headless run, no
--- transport) an `ai-draft` intent is handled as `form`; the result says which mode it ran in.
---
---@see rules.ops
---@see rules.api

local ops = require("rules.ops")
local contract = require("rules.contract")

local M = {}

---@type string
M.SCHEMA = "wkd-intent/1"
---A bigger intent goes as a file or not at all (it must fit a clipboard and a hub request).
---@type integer
M.MAX_BYTES = 64 * 1024
---@type integer
M.MAX_TITLE = 120
---@type integer
M.MAX_SHORT = 300

---@type table<string, boolean>
M.ACTIONS = { ["rules.show"] = true, ["rules.new"] = true }

---@type table<string, boolean>
local MODES = { form = true, ["ai-draft"] = true, agent = true }
---@type table<string, boolean>
local CLASSES = { public = true, internal = true }
---@type table<string, boolean>
local SEVERITIES = { critical = true, recommended = true, ["nice-to-have"] = true }

---@class Rules.Intent
---@field schema string
---@field action "rules.show"|"rules.new"
---@field mode "form"|"ai-draft"|"agent"
---@field target? { id?: string }
---@field finding? table

---@class Rules.IntentError
---@field code string  # too_large, bad_json, bad_schema, bad_action, bad_mode, bad_class, bad_field
---                      # absolute_path, no_target, no_family
---@field message string

---@param code string
---@param message string
---@return nil, Rules.IntentError
local function fail(code, message)
  return nil, { code = code, message = message }
end

---Does a string look like a path of some machine (`/home/x`, `C:\x`, `\\host\x`)?
---@param value string
---@return boolean
local function absolute(value)
  return value:match("^%a:[\\/]") ~= nil or value:match("^[\\/][\\/]") ~= nil or value:match("^/[%w_.~%-]") ~= nil
end

---The first path of this machine anywhere in the value, depth limited.
---@param value any
---@param depth integer
---@return string|nil
local function find_absolute(value, depth)
  if type(value) == "string" then
    return absolute(value) and value or nil
  end
  if type(value) ~= "table" or depth > 6 then
    return nil
  end
  for _, v in pairs(value) do
    local hit = find_absolute(v, depth + 1)
    if hit then
      return hit
    end
  end
  return nil
end

---A short single-line string: these values end up in the text of a rule, so no newline or other control
---character may smuggle markup in.
---@param value any
---@param max integer
---@return boolean
local function plain(value, max)
  return type(value) == "string" and #value <= max and not value:find("[%c]")
end

---Does a text carry a control character other than newline and tab?
---@param text string
---@return boolean
local function has_control(text)
  local stripped = text:gsub("[\n\t]", "")
  return stripped:find("%c") ~= nil
end

---Check and normalise an intent.
---@param input string|table  JSON text or the decoded table
---@return Rules.Intent|nil intent
---@return Rules.IntentError|nil err
function M.parse(input)
  local data = input
  if type(input) == "string" then
    if #input > M.MAX_BYTES then
      return fail("too_large", ("an intent is at most %d bytes"):format(M.MAX_BYTES))
    end
    local ok, decoded = pcall(vim.json.decode, input)
    if not ok or type(decoded) ~= "table" then
      return fail("bad_json", "the intent is not a JSON object")
    end
    data = decoded
  elseif type(input) ~= "table" then
    return fail("bad_json", "the intent is not a JSON object")
  end

  if data.schema ~= M.SCHEMA then
    return fail("bad_schema", ("schema must be %s"):format(M.SCHEMA))
  end
  if type(data.action) ~= "string" or not M.ACTIONS[data.action] then
    return fail("bad_action", "this engine accepts only rules.show and rules.new")
  end
  local mode = data.mode == nil and "form" or data.mode
  if type(mode) ~= "string" or not MODES[mode] then
    return fail("bad_mode", "mode must be form, ai-draft or agent")
  end
  if data.target ~= nil and type(data.target) ~= "table" then
    return fail("bad_field", "target must be an object")
  end
  if data.finding ~= nil and type(data.finding) ~= "table" then
    return fail("bad_field", "finding must be an object")
  end
  local finding = data.finding or {}
  if finding.class ~= nil and not CLASSES[finding.class] then
    return fail("bad_class", "only public and internal findings may leave the testing app")
  end
  if data.action == "rules.new" and finding.class == nil then
    return fail("bad_class", "a finding without a data class is refused (unclassified)")
  end
  local hit = find_absolute(data, 0)
  if hit then
    return fail("absolute_path", "an intent never carries a path of another machine")
  end
  if finding.title ~= nil and not plain(finding.title, M.MAX_TITLE) then
    return fail("bad_field", ("finding.title is a single-line string of at most %d bytes"):format(M.MAX_TITLE))
  end
  for _, key in ipairs({ "repo", "sha", "rule", "severity", "family" }) do
    local v = finding[key]
    if v ~= nil and not plain(v, M.MAX_SHORT) then
      return fail("bad_field", ("finding.%s is a single-line string of at most %d bytes"):format(key, M.MAX_SHORT))
    end
  end
  if finding.where ~= nil then
    local where = finding.where
    if type(where) ~= "table" then
      return fail("bad_field", "finding.where must be an object")
    end
    if where.file ~= nil and not plain(where.file, M.MAX_SHORT) then
      return fail("bad_field", "finding.where.file is a single-line string")
    end
    if where.line ~= nil and not (type(where.line) == "number" and where.line >= 0 and where.line % 1 == 0) then
      return fail("bad_field", "finding.where.line is a non-negative integer")
    end
  end
  if data.target and data.target.id ~= nil and (type(data.target.id) ~= "string" or #data.target.id > M.MAX_SHORT) then
    return fail("bad_field", "target.id is a short string")
  end
  return {
    schema = data.schema,
    action = data.action,
    mode = mode,
    target = data.target,
    finding = finding,
  }
end

---The rule id an intent points at (`target.id`, else `finding.rule`).
---@param intent Rules.Intent
---@return string|nil
local function rule_id(intent)
  local id = intent.target and intent.target.id or intent.finding and intent.finding.rule
  if type(id) == "string" and id:match("^%a+%-%d+$") then
    return id
  end
  return nil
end

---The reference that stands for the evidence: `file:line` and `repo@sha`, repo-relative, no excerpt.
---@param finding table
---@return string|nil
local function evidence(finding)
  local parts = {}
  local where = type(finding.where) == "table" and finding.where or nil
  if where and type(where.file) == "string" and where.file ~= "" then
    local at = where.file
    if type(where.line) == "number" then
      at = ("%s:%d"):format(at, where.line)
    end
    parts[#parts + 1] = ("`%s`"):format(at)
  end
  if type(finding.repo) == "string" and finding.repo ~= "" then
    local sha = type(finding.sha) == "string" and finding.sha:match("^%x+$") and finding.sha:sub(1, 7) or nil
    parts[#parts + 1] = ("`%s%s`"):format(finding.repo, sha and ("@" .. sha) or "")
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " in ")
end

---Map a `rules.new` intent to the `new` operation of the ops door.
---@param intent Rules.Intent
---@param opts? { family?: string, severity?: string, body?: string }  `body`: the drafted prose (mode `ai-draft`)
---@return table|nil op
---@return Rules.IntentError|nil err
function M.new_op(intent, opts)
  opts = opts or {}
  local finding = intent.finding or {}
  local title = finding.title
  if type(title) ~= "string" or title == "" then
    return fail("bad_field", "rules.new needs finding.title")
  end
  local suggestion = rule_id(intent)
  local family = opts.family or finding.family or (suggestion and suggestion:match("^(%a+)%-"))
  if not family then
    return fail("no_family", "no family given: pass one (a proposal is not guessed)")
  end
  local severity = opts.severity or finding.severity
  if severity == nil then
    severity = "recommended"
  elseif not SEVERITIES[severity] then
    return fail("bad_field", "severity must be critical, recommended or nice-to-have")
  end
  local text = (type(opts.body) == "string" and opts.body ~= "") and opts.body or (title .. ".")
  if has_control(text) then
    return fail("bad_field", "the body carries a control character")
  end
  local ref = evidence(finding)
  if ref then
    text = text .. "\n\nEvidence: " .. ref .. "."
  end
  return { op = "new", family = family, title = title, severity = severity, text = text }
end

---What a model is asked to word for a `rules.new` intent: the same title, family, severity and evidence
---*reference* the rule would carry, nothing else (see `engine/agent/draft`).
---@param intent Rules.Intent
---@param opts? { family?: string, severity?: string }
---@return Rules.Draft.Subject|nil subject
---@return Rules.IntentError|nil err
function M.draft_subject(intent, opts)
  if intent.action ~= "rules.new" then
    return fail("bad_action", "only rules.new is drafted")
  end
  local op, err = M.new_op(intent, opts)
  if not op then
    return nil, err
  end
  return {
    title = op.title,
    family = op.family,
    severity = op.severity,
    reference = evidence(intent.finding or {}),
  }
end

---The mode a run really ran in: `ai-draft` only when a drafted body came with it, else the form's.
---@param intent Rules.Intent
---@param opts? { body?: string }
---@return "form"|"ai-draft"|"agent"
function M.mode_of(intent, opts)
  if intent.mode == "ai-draft" and not (opts and type(opts.body) == "string" and opts.body ~= "") then
    return "form"
  end
  return intent.mode
end

---Run an intent against the engine.
---@param intent Rules.Intent
---@param opts? table  engine options (`rulesets`, `vault`, ...) plus `family`, `severity`, `yes`
---@return table|nil result  `{ action, mode, dry_run?, document }`
---@return Rules.IntentError|nil err
function M.run(intent, opts)
  opts = opts or {}
  if intent.action == "rules.show" then
    local id = rule_id(intent)
    if not id then
      return fail("no_target", "rules.show needs target.id (an id like LUA-12)")
    end
    local doc, err = contract.rule(id, opts)
    if not doc then
      return fail("no_target", type(err) == "table" and tostring(err.message or err.code) or tostring(err))
    end
    return { action = intent.action, mode = intent.mode, document = doc }
  end

  local op, err = M.new_op(intent, opts)
  if not op then
    return nil, err
  end
  local dry_run = opts.yes ~= true
  local doc, run_err = ops.run({ ops = { op }, dry_run = dry_run }, opts)
  if not doc then
    return fail("bad_field", type(run_err) == "table" and tostring(run_err.message or run_err.code) or tostring(run_err))
  end
  local entry = doc.results and doc.results[1]
  if entry and entry.ok == false then
    local why = entry.error and (entry.error.message or entry.error.code) or "the operation failed"
    return fail("bad_field", tostring(why))
  end
  return { action = intent.action, mode = M.mode_of(intent, opts), dry_run = dry_run, document = doc }
end

return M
