-- The :Rules commands of the bindings checklist of the nvim config that read the rules and report
-- (BINDINGS-RUNTIME-CHECKLIST.md, section ":Rules": messages, list, stats, show, check, gate, catalog): each is typed
-- on the command line with the setup of the nvim config on a fixture vault (TESTS/sheets/_bindings.lua), and the sheet
-- reads what it did -- the report tab, the quickfix list, the rule file it jumped to, the documents it wrote.
-- The commands that change rules and waivers are in rules-bindings-write.sheet.lua, :RulesVault in
-- rules-bindings-vault.sheet.lua.

local steps = {
  {
    lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")]],
    note = "rules.setup as in the nvim config, on a fixture vault; the cwd is the fixture project",
  },
}

local function add(step)
  steps[#steps + 1] = step
end

---Type `:cmd` and check what it did.
local function cmd(line, expect, note)
  add({ keys = ":" .. line .. "<CR>", note = ":" .. line .. ": " .. note })
  add({ expect = expect, note = ":" .. line .. " " .. note })
end

---Type `:cmd` that refuses: the refusal is an error message (`v:errmsg`) and nothing else happens.
local function refuse(line, text, note)
  add({ keys = ":" .. line .. "<CR>", ignore_errmsg = true, note = ":" .. line .. ": " .. note })
  add({
    expect = ("vim.v.errmsg:find(%q, 1, true) ~= nil"):format(text),
    note = ":" .. line .. " " .. note,
  })
end

---Close the report tab a command opened.
local function close_tab()
  add({ keys = ":tabclose<CR>", note = "close the report tab" })
end

cmd(
  "Rules stats",
  [[vim.bo.filetype == "rulesreport" and #vim.api.nvim_list_tabpages() == 2
    and _G.buftext():find("2 rule(s) loaded", 1, true)
    and _G.buftext():find("DEP%s+2%s+1%s+1%s+1%s+1%s+0")]],
  "opens the overview in a tab: per family total, checked, manual and the severities"
)
close_tab()

cmd(
  "Rules list",
  [[#vim.fn.getqflist() == 2 and _G.qftext() == "DEP-01 [recommended] No FIXME left\nDEP-02 [critical] Pin every dependency"
    and _G.said("2 rule(s) in the quickfix list", true)]],
  "puts every rule in the quickfix list"
)
cmd(
  "Rules list --family=DEP --severity=critical",
  [[_G.qftext() == "DEP-02 [critical] Pin every dependency" and _G.said("1 rule(s) in the quickfix list", true)]],
  "narrows it by family and severity"
)
-- the JSON goes to :messages, a long message: read as `:execute` reads it, as a script would capture it
add({
  lua = [[_G.json = vim.json.decode(vim.trim(vim.fn.execute("Rules list --format=json")))]],
  note = ":Rules list --format=json prints the document of the machine contract",
})
add({
  expect = [[_G.json.kind == "rules.list" and _G.json.total == 2 and _G.json.items[1].id == "DEP-01"
    and _G.json.items[2].id == "DEP-02"]],
  note = "the rules.list document with both rules",
})
add({ keys = ":cclose<CR>" })

cmd(
  "Rules show DEP-02",
  [[_G.bufpath() == vim.fs.normalize(_G.fx.lua .. "/_rules/DEP/DEP-02.md")
    and vim.api.nvim_get_current_line():find("DEP-02", 1, true) ~= nil]],
  "jumps to the rule's source line"
)
refuse("Rules show NOPE-01", 'no loaded rule with id "NOPE-01"', "refuses an id no rule has")

cmd(
  "Rules check --family=DEP",
  [[vim.bo.filetype == "rulesreport" and _G.buftext():find("DEP-01 -- 1 finding(s)", 1, true)
    and _G.buftext():find("main.lua:1: local x = 1 -- FIXME", 1, true)
    and _G.buftext():find("no automated check, review by hand", 1, true)
    and #vim.fn.getqflist() == 1 and _G.qftext() == "[DEP-01] local x = 1 -- FIXME: name it"]],
  "sweeps the family over the cwd: the finding in the report and in the quickfix list, the manual rule listed"
)
close_tab()

add({
  lua = [[_G.json = vim.json.decode(vim.trim(vim.fn.execute("Rules check --family=DEP --format=json")))]],
  note = ":Rules check --format=json prints the results instead of the report",
})
add({
  expect = [[#_G.json == 2 and _G.json[1].id == "DEP-01" and _G.json[1].status == "fail"
    and _G.json[1].findings[1].line == 1 and _G.json[2].status == "manual"
    and vim.bo.filetype ~= "rulesreport"]],
  note = "one result per rule, the finding with its line; no report tab",
})

cmd(
  "Rules gate review",
  [[vim.bo.filetype == "rulesreport" and _G.buftext():find("DEP-01 -- 1 finding(s)", 1, true)
    and #vim.fn.getqflist() == 1]],
  "runs the families of the configured gate"
)
close_tab()
-- --diff: the project as a git repository whose last commit has main.lua; a new file with a finding beside it
add({
  lua = [[local g = { "git", "-c", "commit.gpgsign=false", "-c", "user.name=sheet", "-c", "user.email=sheet@example.test" }
    for _, a in ipairs({ { "init", "-q" }, { "add", "-A" }, { "commit", "-q", "-m", "base" } }) do
      vim.fn.system(vim.list_extend(vim.list_slice(g), a))
      assert(vim.v.shell_error == 0, "git " .. a[1])
    end
    vim.fn.writefile({ "-- FIXME: new" }, _G.fx.project .. "/new.lua")]],
  note = "the project in git; new.lua (FIXME) is not committed",
})
cmd(
  "Rules gate review --diff=HEAD",
  [[vim.bo.filetype == "rulesreport" and #vim.fn.getqflist() == 1 and _G.qftext() == "[DEP-01] -- FIXME: new"
    and not _G.buftext():find("main.lua", 1, true)]],
  "narrows the findings to the files changed since the ref"
)
close_tab()
cmd(
  "Rules gate release",
  [[_G.said('gate "release": family "REL" matches no loaded rule', true)]],
  "warns that the family of the gate matches no loaded rule"
)
add({ lua = [[if vim.bo.filetype == "rulesreport" then vim.cmd.tabclose() end]] })

cmd(
  "Rules catalog",
  [[_G.read(_G.fx.lua .. "/Dependencies.md") ~= nil
    and _G.read(_G.fx.lua .. "/Dependencies.md"):find("No FIXME left", 1, true)
    and _G.said("catalog: 1 written, 0 unchanged, 0 stale, 0 with errors", true)]],
  "builds the reading document of the layout"
)
cmd(
  "Rules catalog --check",
  [[_G.said("catalog: 0 written, 1 unchanged, 0 stale, 0 with errors", true)]],
  "finds it up to date and writes nothing"
)
-- a compact document: a layout with `folder` and `families: all`, and a generated document no layout makes any more
add({
  lua = [[local catalog = require("rules.engine.catalog")
    local function put(path, text)
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local f = assert(io.open(path, "wb"))
      f:write(text)
      f:close()
    end
    put(_G.fx.lua .. "/_kontext/kurz.md", table.concat({ "---", "kind: layout", "output: kontext/kurz.md",
      "folder: kontext", "families: all", "---", "# Kurz", "", "{{family DEP brief}}", "" }, "\n"))
    put(_G.fx.lua .. "/kontext/alt.md", catalog.header("_kontext/alt.md") .. "\nalt\n")]],
  note = "a kontext layout ({{family DEP brief}}) and a stale generated document in its folder",
})
cmd(
  "Rules catalog",
  [[_G.read(_G.fx.lua .. "/kontext/kurz.md") ~= nil
    and _G.read(_G.fx.lua .. "/kontext/kurz.md"):find("\n- `DEP-01` **No FIXME left**: Text of DEP-01.\n", 1, true)
    and _G.read(_G.fx.lua .. "/kontext/alt.md") == nil
    and _G.said("catalog: 1 written, 1 unchanged, 0 stale, 0 with errors, 1 removed", true)]],
  "writes the compact document and removes the stale one of the folder"
)

-- the messages of the steps before are in the history; one more so the viewer has a line this sheet knows
add({ lua = [[require("rules.util.notify").info("sheet marker line")]] })
cmd("Rules messages", [[_G.buftext():find("sheet marker line", 1, true) ~= nil]], "opens the notify history of rules.nvim")

return {
  id = "rules.bindings-read",
  title = "The reading :Rules commands of the nvim config report what the rules say about the project",
  task = "rules.nvim/abnahme-bindings-testblaetter",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = steps,
  manual = {
    "In the real config (rulesets = the lua ruleset of $RULES_VAULT): :Rules stats, :Rules check --family=ERR and "
      .. ":Rules gate review answer within a few seconds and the report reads well",
  },
}
