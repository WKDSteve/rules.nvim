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

cmd(
  "Rules gate review",
  [[vim.bo.filetype == "rulesreport" and _G.buftext():find("DEP-01 -- 1 finding(s)", 1, true)
    and #vim.fn.getqflist() == 1]],
  "runs the families of the configured gate"
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
