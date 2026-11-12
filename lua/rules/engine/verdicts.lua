---@module 'rules.engine.verdicts'
---@brief `.rules-verdicts.json`: the verdicts a person accepted from an agent's proposal.
---@description
--- A manual rule has no check, so a run can only list it. An agent can propose an answer (`engine/agent/validate`);
--- that is not a verdict. A verdict exists only when a person looks at one proposal and accepts it, and this file is
--- where that is kept: committed, next to `.rules-waivers.json`, written by `M.accept` and by nothing else.
---
--- ```json
--- { "DEP-01": { "verdict": "compliant", "date": "2026-10-22", "by": "Stefan",
---               "evidence": [ { "file": "lua/a.lua", "line": 12 }, { "file": "lua/b.lua" } ],
---               "note": "checked the two entry points", "from_proposal": { "status": "compliant" } } }
--- ```
---
--- What the store guarantees:
---   * One actor does not both propose and verify. `accept` takes one proposal at a time (no "accept all"), refuses
---     a proposal that says `verified`, and an `unclear` one (that is the absence of an answer, not an answer); the
---     person's name (`by`) comes from the caller, never from the proposal.
---   * The person accepts what was proposed. `verdict` is the proposal's `status`; a person who disagrees rejects, and
---     there is nothing to write.
---   * A file that exists but cannot be used is an error, never "no verdicts" (the loader of `.rules-waivers.json`
---     is strict in the same way).
---   * A verdict does not change what `:Rules check` or `:Rules gate` report, and never the exit code.
---
--- Whether a verdict is still current is a pure function (`M.stale`): the caller says which files and rules changed
--- on which day (from `git log`, the engine runs no git), the function compares them with the verdict's date and the
--- evidence it named.

local safe_error = require("lib.lua.error")
local waivers = require("rules.engine.waivers")

local M = {}

--- The file name at the project root.
M.FILE = ".rules-verdicts.json"

M.MAX_VERDICTS = 1000
M.MAX_EVIDENCE = 50
M.MAX_NOTE_LEN = waivers.MAX_REASON_LEN
M.MAX_BY_LEN = 100

---@class Rules.Verdict.Evidence
---@field file string  relative to the project root, `/`, no glob
---@field line? integer

---@class Rules.Verdict
---@field verdict "compliant"|"violation"  what the person accepted
---@field date string  `YYYY-MM-DD`: the day it was accepted
---@field by string  the person
---@field evidence Rules.Verdict.Evidence[]  where the answer was found (may be empty)
---@field evidence_omitted? integer  how many more files the proposal named than `evidence` keeps (`M.MAX_EVIDENCE`)
---@field note? string
---@field commit? string  the commit the tree was at when it was accepted (given by the caller; the engine runs no git)
---@field scope? { count: integer, hash: string }  the files the request carried: how many, and the hash of the sorted list
---@field from_proposal? { status: "compliant"|"violation", model?: string }  what was accepted

---@alias Rules.Verdicts table<string, Rules.Verdict>

local VERDICTS = { compliant = true, violation = true }
local KEYS = { "by", "commit", "date", "evidence", "evidence_omitted", "from_proposal", "note", "scope", "verdict" }
local SCOPE_KEYS = { "count", "hash" }
local EVIDENCE_KEYS = { "file", "line" }
local PROPOSAL_KEYS = { "model", "status" }

---@param text string
---@return integer
local function chars(text)
  return vim.fn.strchars(text)
end

---@param value any
---@param keys string[]
---@return string|nil unknown
local function unknown_key(value, keys)
  for key in pairs(value) do
    if not vim.tbl_contains(keys, key) then
      return tostring(key):sub(1, 40)
    end
  end
  return nil
end

--- Why a one-line text cannot be used, or nil.
---@param text any
---@param max integer
---@return string|nil why
local function line_error(text, max)
  if type(text) ~= "string" then
    return "must be a text"
  end
  if text:find("\n", 1, true) or text:find("[%z\1-\8\11-\31\127]") then
    return "must be one line with no control character"
  end
  if chars(text) > max then
    return ("exceeds %d characters"):format(max)
  end
  return nil
end

--- Why an evidence entry cannot be used, or nil: a plain relative file (no glob) and, when given, a line of 1 or more.
---@param evidence any
---@return string|nil why
local function evidence_error(evidence)
  if type(evidence) ~= "table" or evidence == vim.NIL or vim.islist(evidence) and #evidence > 0 then
    return "an evidence entry must be an object with file and line"
  end
  local unknown = unknown_key(evidence, EVIDENCE_KEYS)
  if unknown then
    return ("unknown key %q in an evidence entry (keys: %s)"):format(unknown, table.concat(EVIDENCE_KEYS, ", "))
  end
  local why = waivers.path_error(evidence.file)
  if why then
    return "evidence file: " .. why
  end
  if evidence.file:find("[%*%?%[%]{}]") or evidence.file:sub(-1) == "/" then
    return "evidence file must name one file, not a glob or a folder"
  end
  if evidence.line ~= nil then
    local line = evidence.line
    if type(line) ~= "number" or line % 1 ~= 0 or line < 1 then
      return "evidence line must be a whole number of 1 or more"
    end
  end
  return nil
end

--- Check one entry and bring it to the full form.
---@param id string
---@param value any
---@return Rules.Verdict|nil entry
---@return string|nil why  without the file's name
function M.entry(id, value)
  if type(value) ~= "table" or value == vim.NIL or (next(value) ~= nil and vim.islist(value)) then
    return nil, ("the verdict for %s must be an object"):format(id)
  end
  local unknown = unknown_key(value, KEYS)
  if unknown then
    return nil, ("unknown key %q in the verdict for %s (keys: %s)"):format(unknown, id, table.concat(KEYS, ", "))
  end
  if type(value.verdict) ~= "string" or not VERDICTS[value.verdict] then
    return nil, ("verdict for %s must be compliant or violation"):format(id)
  end
  if not waivers.valid_date(value.date) then
    return nil, ("date for %s must be a calendar date in the form YYYY-MM-DD"):format(id)
  end
  local by_why = line_error(value.by, M.MAX_BY_LEN)
  if by_why or vim.trim(value.by) == "" then
    return nil, ("by for %s %s"):format(id, by_why or "must name a person")
  end
  local entry = { verdict = value.verdict, date = value.date, by = value.by, evidence = {} }

  if value.evidence ~= nil then
    if
      type(value.evidence) ~= "table"
      or value.evidence == vim.NIL
      or (next(value.evidence) ~= nil and not vim.islist(value.evidence))
    then
      return nil, ("evidence for %s must be a list"):format(id)
    end
    if #value.evidence > M.MAX_EVIDENCE then
      return nil, ("evidence for %s has more than %d entries"):format(id, M.MAX_EVIDENCE)
    end
    for _, item in ipairs(value.evidence) do
      local why = evidence_error(item)
      if why then
        return nil, ("evidence for %s: %s"):format(id, why)
      end
      entry.evidence[#entry.evidence + 1] = { file = item.file, line = item.line }
    end
  end

  if value.evidence_omitted ~= nil then
    local omitted = value.evidence_omitted
    if type(omitted) ~= "number" or omitted % 1 ~= 0 or omitted < 1 then
      return nil, ("evidence_omitted for %s must be a whole number of 1 or more"):format(id)
    end
    entry.evidence_omitted = omitted
  end

  if value.note ~= nil then
    local why = waivers.reason_error(value.note)
    if why then
      return nil, ("note for %s %s"):format(id, why)
    end
    entry.note = value.note
  end

  if value.commit ~= nil then
    if type(value.commit) ~= "string" or not value.commit:match("^%x+$") or #value.commit < 7 or #value.commit > 64 then
      return nil, ("commit for %s must be a hexadecimal commit id of 7 to 64 characters"):format(id)
    end
    entry.commit = value.commit
  end

  if value.scope ~= nil then
    local scope = value.scope
    if type(scope) ~= "table" or scope == vim.NIL or vim.islist(scope) and #scope > 0 then
      return nil, ("scope for %s must be an object"):format(id)
    end
    local bad_scope = unknown_key(scope, SCOPE_KEYS)
    if bad_scope then
      return nil, ("unknown key %q in scope for %s (keys: %s)"):format(bad_scope, id, table.concat(SCOPE_KEYS, ", "))
    end
    if type(scope.count) ~= "number" or scope.count % 1 ~= 0 or scope.count < 0 then
      return nil, ("scope.count for %s must be a whole number of 0 or more"):format(id)
    end
    if type(scope.hash) ~= "string" or not scope.hash:match("^%x+$") or #scope.hash ~= 64 then
      return nil, ("scope.hash for %s must be a SHA-256 in hexadecimal"):format(id)
    end
    entry.scope = { count = scope.count, hash = scope.hash }
  end

  if value.from_proposal ~= nil then
    local origin = value.from_proposal
    if type(origin) ~= "table" or origin == vim.NIL or vim.islist(origin) and #origin > 0 then
      return nil, ("from_proposal for %s must be an object"):format(id)
    end
    local bad = unknown_key(origin, PROPOSAL_KEYS)
    if bad then
      return nil, ("unknown key %q in from_proposal for %s (keys: %s)"):format(bad, id, table.concat(PROPOSAL_KEYS, ", "))
    end
    if type(origin.status) ~= "string" or not VERDICTS[origin.status] then
      return nil, ("from_proposal.status for %s must be compliant or violation"):format(id)
    end
    if origin.model ~= nil and line_error(origin.model, M.MAX_BY_LEN) then
      return nil, ("from_proposal.model for %s must be one line of at most %d characters"):format(id, M.MAX_BY_LEN)
    end
    if origin.status ~= value.verdict then
      return nil,
        ("from_proposal.status for %s is %s but the verdict is %s: a person accepts what was proposed"):format(
          id,
          origin.status,
          value.verdict
        )
    end
    entry.from_proposal = { status = origin.status, model = origin.model }
  end
  return entry, nil
end

--- Parse the text of a verdicts file. Every field is re-validated; nothing is skipped.
---@param raw string
---@param label string  how an error names the file
---@return Rules.Verdicts|nil entries
---@return string|nil err
function M.parse(raw, label)
  raw = raw:gsub("^\239\187\191", "")
  local ok, decoded = safe_error.safe_call(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil, label .. ": could not parse as JSON"
  end
  if next(decoded) ~= nil and vim.islist(decoded) then
    return nil, label .. ': must be a JSON object of {"RULE-ID": { ... }}, not a list'
  end
  local entries, count = {}, 0
  for id, value in pairs(decoded) do
    local id_why = waivers.id_error(id)
    if id_why then
      return nil, ("%s: %s"):format(label, id_why)
    end
    local entry, why = M.entry(id, value)
    if not entry then
      return nil, ("%s: %s"):format(label, why)
    end
    entries[id] = entry
    count = count + 1
    if count > M.MAX_VERDICTS then
      return nil, ("%s: more than %d verdicts"):format(label, M.MAX_VERDICTS)
    end
  end
  return entries, nil
end

---@param root string
---@return string
function M.path(root)
  return root .. "/" .. M.FILE
end

--- Load `<root>/.rules-verdicts.json`. A missing file means no verdicts; one that exists and cannot be used is an
--- error.
---@param root string
---@return Rules.Verdicts entries  `{}` on an error
---@return string|nil error
function M.load(root)
  local path = M.path(root)
  if vim.fn.filereadable(path) == 0 then
    if vim.uv.fs_lstat(path) then
      return {}, path .. ": could not read (not a readable file)"
    end
    return {}, nil
  end
  local read_ok, lines = safe_error.safe_call(vim.fn.readfile, path)
  if not read_ok then
    return {}, ("%s: could not read (%s)"):format(path, lines.message)
  end
  local entries, err = M.parse(table.concat(lines, "\n"), path)
  if not entries then
    return {}, err
  end
  return entries, nil
end

--- The text of a verdicts file: sorted keys, two spaces, LF and a final newline.
---@param entries Rules.Verdicts
---@return string
function M.encode(entries)
  local json = require("lib.nvim.json.canonical")
  local doc = {}
  for id, entry in pairs(entries) do
    local evidence = {}
    for _, item in ipairs(entry.evidence or {}) do
      evidence[#evidence + 1] = json.object({ file = item.file, line = item.line })
    end
    doc[id] = json.object({
      verdict = entry.verdict,
      date = entry.date,
      by = entry.by,
      evidence = json.array(evidence),
      evidence_omitted = entry.evidence_omitted,
      note = entry.note,
      commit = entry.commit,
      scope = entry.scope and json.object({ count = entry.scope.count, hash = entry.scope.hash }) or nil,
      from_proposal = entry.from_proposal
          and json.object({ status = entry.from_proposal.status, model = entry.from_proposal.model })
        or nil,
    })
  end
  return json.encode(json.object(doc), { indent = 2 }) .. "\n"
end

-- ── accepting ───────────────────────────────────────────────────────────────────

--- The bytes of a file, nil when there is none.
---@param path string
---@return string|nil
local function read_bytes(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local text = fh:read("*a")
  fh:close()
  return text
end

---@class Rules.Verdict.Accept
---@field by string  the person who accepts; required, and never taken from the proposal
---@field date? string  `YYYY-MM-DD`; default: today
---@field note? string
---@field evidence? Rules.Verdict.Evidence[]  default: the proposal's findings (file, line), or its `checked` files
---@field model? string  the model that made the proposal, kept as the origin
---@field commit? string  the commit the tree is at (`git rev-parse HEAD`), kept so a later change can be told by commit

---@param files string[]
---@return string
local function scope_hash(files)
  local sorted = {}
  for index, file in ipairs(files) do
    sorted[index] = (tostring(file):gsub("\\", "/"))
  end
  table.sort(sorted)
  return vim.fn.sha256(table.concat(sorted, "\n"))
end

--- The scope record of a list of files: how many, and the hash of the sorted list.
---@param files string[]
---@return { count: integer, hash: string }
function M.scope_of(files)
  return { count = #files, hash = scope_hash(files) }
end

--- Why the evidence cannot be accepted against this tree, or nil: each file must be one the request carried and
--- exist in the tree as a plain file (not a link, not a folder). A host that builds a proposal by hand cannot name
--- evidence that was never sent or does not exist.
---@param root string
---@param evidence Rules.Verdict.Evidence[]
---@param sent string[]|nil
---@return string|nil why
local function evidence_tree_error(root, evidence, sent)
  if type(sent) ~= "table" then
    return "the proposal carries no list of the files that were sent: its evidence cannot be checked"
  end
  local sent_set = {}
  for _, path in ipairs(sent) do
    sent_set[(tostring(path):gsub("\\", "/"))] = true
  end
  for _, item in ipairs(evidence) do
    if not sent_set[item.file] then
      return ("evidence file %s was not sent with the request"):format(item.file)
    end
    local stat = vim.uv.fs_lstat(root .. "/" .. item.file)
    if not stat or stat.type ~= "file" then
      return ("evidence file %s is not a file in the tree"):format(item.file)
    end
  end
  return nil
end

--- The evidence a proposal carries by itself, at most `M.MAX_EVIDENCE` entries.
---@param proposal table
---@return Rules.Verdict.Evidence[] evidence
---@return integer|nil omitted  how many more it names
local function evidence_of(proposal)
  local out, seen = {}, {}
  for _, finding in ipairs(proposal.findings or {}) do
    local key = ("%s:%s"):format(finding.file, tostring(finding.line))
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = { file = finding.file, line = finding.line }
    end
  end
  if #out == 0 then
    for _, file in ipairs(proposal.checked or {}) do
      out[#out + 1] = { file = file }
    end
  end
  if #out > M.MAX_EVIDENCE then
    local omitted = #out - M.MAX_EVIDENCE
    local kept = {}
    for index = 1, M.MAX_EVIDENCE do
      kept[index] = out[index]
    end
    return kept, omitted
  end
  return out, nil
end

--- Turn one proposal into a verdict entry, without writing anything.
---@param proposal Rules.Agent.Result  from `engine/agent/validate`
---@param accept Rules.Verdict.Accept
---@param root? string  when given, the evidence is checked against the tree and the files the request carried
---@return string|nil id
---@return Rules.Verdict|nil entry
---@return string|nil err
function M.accepted(proposal, accept, root)
  if type(proposal) ~= "table" or (next(proposal) ~= nil and vim.islist(proposal)) then
    return nil, nil, "accept takes one proposal at a time"
  end
  if type(proposal.rule_id) ~= "string" or proposal.proposed ~= true then
    return nil, nil, "this is not a proposal of the agent (no rule_id, or not marked proposed)"
  end
  if proposal.verified ~= false then
    return nil, nil, "a proposal that says it is verified is refused: the one who proposes does not confirm"
  end
  if not VERDICTS[proposal.status] then
    return nil, nil, "a proposal that is " .. tostring(proposal.status) .. " is not a verdict: nothing to accept"
  end
  if type(accept) ~= "table" or type(accept.by) ~= "string" then
    return nil, nil, "accept needs `by`: the person who accepts"
  end
  local today, today_err = waivers.today(accept.date)
  if not today then
    return nil, nil, today_err
  end
  if today > waivers.clock() then
    return nil, nil, "the date is in the future: a verdict dated ahead would never go stale"
  end
  local evidence, omitted = accept.evidence, nil
  if not evidence then
    evidence, omitted = evidence_of(proposal)
  end
  if root then
    local tree_why = evidence_tree_error(root, evidence, proposal.sent)
    if tree_why then
      return nil, nil, tree_why
    end
  end
  local entry, why = M.entry(proposal.rule_id, {
    commit = accept.commit,
    scope = type(proposal.sent) == "table" and M.scope_of(proposal.sent) or nil,
    verdict = proposal.status,
    date = today,
    by = accept.by,
    evidence = evidence,
    evidence_omitted = omitted,
    note = accept.note,
    from_proposal = { status = proposal.status, model = accept.model },
  })
  if not entry then
    return nil, nil, why
  end
  return proposal.rule_id, entry, nil
end

--- Accept one proposal: the verdict of its rule is written to `<root>/.rules-verdicts.json`, replacing an earlier
--- verdict of the same rule. This is the only function that writes the file. An existing file that cannot be used, or
--- is a link, stops it: the engine does not guess what to overwrite.
---@param root string
---@param proposal Rules.Agent.Result
---@param accept Rules.Verdict.Accept
---@return boolean ok
---@return string|nil err
function M.accept(root, proposal, accept)
  local id, entry, err = M.accepted(proposal, accept, root)
  if not id then
    return false, err
  end
  local path = M.path(root)
  local stat = vim.uv.fs_lstat(path)
  if stat and stat.type == "link" then
    return false, M.FILE .. " is a link: edit the file it points to by hand, the engine does not write through a link"
  end
  local before = read_bytes(path)
  local entries, load_err = M.load(root)
  if load_err then
    return false, load_err
  end
  local count = 0
  for _ in pairs(entries) do
    count = count + 1
  end
  if entries[id] == nil and count >= M.MAX_VERDICTS then
    return false, ("%s already has %d verdicts"):format(M.FILE, M.MAX_VERDICTS)
  end
  entries[id] = entry
  local text = M.encode(entries)
  -- Another session may have accepted a verdict since the read: do not replace what we did not see.
  if read_bytes(path) ~= before then
    return false, M.FILE .. " changed while the verdict was being accepted; accept again"
  end
  local ok = require("lib.nvim.fs.write.atomic")(path, text)
  if not ok then
    return false, path .. ": could not write"
  end
  return true, nil
end

-- ── what became of a verdict ────────────────────────────────────────────────────

--- Verdict ids that match no loaded rule (the rule was retired or renamed).
M.orphaned = waivers.orphaned

---@class Rules.Verdict.Changes
---@field files? table<string, string>  relative file -> the day it last changed (`YYYY-MM-DD`)
---@field rules? table<string, string>  rule id -> the day its text last changed
---@field scope? table<string, string[]>  rule id -> the files its scope holds now (what `plan` would send today)
---@field since_commit? table<string, string[]>  rule id -> the evidence files (or the rule's own file) that changed
---  after the verdict's `commit` (`git diff --name-only <commit>..HEAD`): catches a change on the day of accepting

---@class Rules.Verdict.Stale
---@field id string
---@field reasons string[]  `file <path> changed <date>` or `rule changed <date>`

--- Which verdicts are out of date: a rule whose text, or a file of its evidence, changed after the day it was
--- accepted. Pure: the caller fills `changes` from the history (`git log -1 --format=%cs -- <path>`).
---@param entries Rules.Verdicts
---@param changes Rules.Verdict.Changes
---@return Rules.Verdict.Stale[] stale  sorted by id
function M.stale(entries, changes)
  local files, rules = changes.files or {}, changes.rules or {}
  local out = {}
  for id, entry in pairs(entries) do
    local reasons = {}
    if rules[id] and rules[id] > entry.date then
      reasons[#reasons + 1] = "rule changed " .. rules[id]
    end
    for _, item in ipairs(entry.evidence) do
      local day = files[item.file]
      if day and day > entry.date then
        reasons[#reasons + 1] = ("file %s changed %s"):format(item.file, day)
      end
    end
    -- The scope now differs from the files the accepted request carried (a file added, or one that left)
    local scope_now = (changes.scope or {})[id]
    if entry.scope and scope_now and scope_hash(scope_now) ~= entry.scope.hash then
      reasons[#reasons + 1] = ("scope changed (%d files then, %d now)"):format(entry.scope.count, #scope_now)
    end
    if entry.commit then
      for _, path in ipairs((changes.since_commit or {})[id] or {}) do
        reasons[#reasons + 1] = ("%s changed after commit %s"):format(path, entry.commit:sub(1, 8))
      end
    end
    if #reasons > 0 then
      out[#out + 1] = { id = id, reasons = reasons }
    end
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

return M
