-- The :RulesVault commands of the bindings checklist of the nvim config (BINDINGS-RUNTIME-CHECKLIST.md, section
-- ":RulesVault" and :RulesVault create of the section after it): each is typed on the command line with the setup of
-- the nvim config on a fixture vault (TESTS/sheets/_bindings.lua), and the sheet reads where it went -- the buffer it
-- opened, the + register, the text at the cursor, what reached the picker, the tree, the files of a new vault.
-- The clipboard is a recording provider and pickers.nvim a recorder (_bindings.lua): that the real picker draws what
-- it is handed is the business of pickers.nvim.

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
local function cmd(line, expect, note, ignore_errmsg)
  add({ keys = ":" .. line .. "<CR>", ignore_errmsg = ignore_errmsg, note = ":" .. line .. ": " .. note })
  add({ expect = expect, note = ":" .. line .. " " .. note })
end

cmd(
  "RulesVault",
  [[_G.text():find("Vault: " .. _G.fx.vault .. " (from setup({ vault = ... }))", 1, true)
    and _G.said("rulesets: lua, native", true)]],
  "shows the vault in use, where it was named and its rulesets"
)

-- ---------- open ----------
cmd(
  "RulesVault open DEP-01",
  [[_G.bufpath() == _G.real(_G.fx.lua .. "/_rules/DEP/DEP-01.md")
    and vim.fn.search("^#### `DEP-01`", "bcnW") >= vim.api.nvim_win_get_cursor(0)[1] - 2
    and vim.fn.search("^#### `DEP-01`", "bcnW") > 0]],
  -- docs/BINDINGS.md says "at its heading"; a rule with a check block is opened at its ```rule line, two below
  -- (rules.nvim/rulesvault-open-auf-der-ueberschrift)
  "opens the rule file at the rule"
)
cmd(
  "RulesVault open DEP",
  [[_G.bufpath() == _G.real(_G.fx.lua .. "/_rules/DEP") and vim.bo.filetype == "netrw"
    and not vim.fn.execute("messages"):find("E%d+:")]],
  "opens the folder of the family (the editor's own explorer: there is no :Filetree)",
  -- netrw lays out its buffer with `sil! unmap`s, which set v:errmsg (E31) without a message
  true
)
cmd(
  "RulesVault open lua layouts",
  [[_G.bufpath() == _G.real(_G.fx.lua .. "/_layouts") and not vim.fn.execute("messages"):find("E%d+:")]],
  "opens a part of a ruleset",
  true
)

-- ---------- clipboard / cdx / link ----------
cmd(
  "RulesVault clipboard DEP-01 --link",
  [[vim.fn.getreg("+") == "[DEP-01](" .. _G.real(_G.fx.lua .. "/_rules/DEP/DEP-01.md") .. ")"
    and _G.said("Copied [DEP-01](", true)]],
  "puts a Markdown link to the rule file into +"
)
cmd(
  "RulesVault clipboard ERR",
  [[vim.fn.getreg("+") == _G.real(_G.fx.native .. "/_rules/ERR")]],
  "puts the path of the family folder into +"
)
cmd(
  "RulesVault cdx DEP",
  [[vim.fn.getreg("+"):find("^Read " .. vim.pesc(_G.real(_G.fx.lua .. "/_rules/DEP")))
    and vim.fn.getreg("+"):find(":Rules new, set, retire and move", 1, true)
    and _G.said("Copied a prompt for DEP", true)]],
  "puts a prompt for an agent session into +"
)
add({
  lua = [[vim.cmd.edit(vim.fn.fnameescape(_G.fx.project .. "/notes.md")); vim.api.nvim_win_set_cursor(0, { 2, 0 })]],
  note = "a Markdown file of the project, the cursor on its empty line",
})
cmd(
  "RulesVault link ERR-100",
  [[vim.api.nvim_get_current_line() == "[ERR-100](../rules-vault/rulesets/native/_rules/ERR/ERR-100.md)"
    and vim.bo.modified]],
  "inserts a link relative to the file at the cursor"
)
add({ lua = [[vim.cmd("silent! write")]] })

-- ---------- find / grep ----------
cmd(
  "RulesVault find lua",
  [[#_G.picked == 1 and _G.picked[1].action == "files" and _G.picked[1].source.prompt == "lua> "
    and _G.real(_G.picked[1].source.roots[1]) == _G.real(_G.fx.lua .. "/_rules")]],
  "hands the rules folder of the ruleset to the file picker"
)
cmd(
  "RulesVault find ERR",
  [[#_G.picked == 2 and _G.picked[2].action == "files" and _G.picked[2].source.prompt == "ERR> "
    and _G.real(_G.picked[2].source.roots[1]) == _G.real(_G.fx.native .. "/_rules/ERR")]],
  "hands the folder of the family to the file picker"
)
cmd(
  "RulesVault grep DEP-01",
  [[#_G.picked == 3 and _G.picked[3].action == "grep" and _G.picked[3].source.query == "DEP-01"
    and _G.real(_G.picked[3].source.roots[1]) == _G.real(_G.fx.lua)]],
  "searches the ruleset of the id for the id"
)

-- ---------- tree ----------
cmd(
  "RulesVault tree lua",
  [[vim.bo.filetype == "rulesreport" and _G.buftext():find("lua  2 rules, 1 retired, 1 family", 1, true)
    and _G.buftext():find("DEP  2 rules, 1 retired", 1, true)
    and _G.buftext():find("DEP-01  [recommended]  No FIXME left", 1, true)
    and _G.buftext():find("DEP-03  [retired]  -> DEP-02", 1, true)]],
  "shows the ruleset as a tree with counts and the retired rule marked"
)
add({ keys = ":tabclose<CR>" })

-- ---------- create ----------
add({
  input = ":RulesVault create new-vault demo<CR>",
  note = ":RulesVault create new-vault demo: another vault is in use, so it asks",
})
add({ wait = [[_G.dialog()]], note = "the plan question" })
add({ keys = "y", note = "answer yes" })
add({
  wait = [[_G.read(_G.fx.project .. "/new-vault/.rules.json") ~= nil]],
  note = "the vault is made",
})
add({
  expect = [[_G.read(_G.fx.project .. "/new-vault/README.md") and _G.read(_G.fx.project .. "/new-vault/.gitattributes")
    and _G.read(_G.fx.project .. "/new-vault/.gitignore")
    and _G.read(_G.fx.project .. "/new-vault/.github/workflows/ci.yml")
    and vim.fn.isdirectory(_G.fx.project .. "/new-vault/rulesets/demo/_rules") == 1
    and vim.fn.isdirectory(_G.fx.project .. "/new-vault/.git") == 0
    and vim.fn.getreg("+"):find('^vault = ".*new%-vault",$')
    and _G.said("ONE STEP IS LEFT, AND IT IS YOURS", true)]],
  note = "folder, README, .rules.json, .gitattributes, .gitignore, CI and the first ruleset; no git; the setup line in +",
})
add({ lua = [[vim.fn.writefile({ "mine" }, _G.fx.project .. "/new-vault/README.md")]], note = "a file of the user" })
add({ input = ":RulesVault create new-vault demo<CR>", note = "create again over the existing vault" })
add({ wait = [[_G.dialog()]] })
add({ keys = "y" })
add({
  wait = [[not _G.dialog() and _G.read(_G.fx.project .. "/new-vault/README.md") == "mine\n"]],
  note = "a file that is there is never overwritten",
})

return {
  id = "rules.bindings-vault",
  title = "The :RulesVault commands of the nvim config open, copy, link, search and show the vault and make one",
  task = "rules.nvim/abnahme-bindings-testblaetter",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = steps,
  manual = {
    "In the real config: :RulesVault find and grep open pickers.nvim's picker on the roots named (snacks), "
      .. ":RulesVault open DEP opens the folder in :Filetree, and the + register reaches the system clipboard",
  },
}
