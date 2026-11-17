-- The :Rules commands of the bindings checklist of the nvim config that change rules, layouts and waivers
-- (BINDINGS-RUNTIME-CHECKLIST.md, section ":Rules": new, set, move, retire, reinstate, waive, renew, and unwaive of the
-- section after it): each is typed on the command line with the setup of the nvim config on a fixture vault
-- (TESTS/sheets/_bindings.lua), the questions are answered as a person answers them (the button dialog of
-- lib.nvim's kit, which looks like ui.nvim's, `n` and `y` its keys), and the sheet reads the files the command wrote.

local steps = {
  {
    lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")]],
    note = "rules.setup as in the nvim config, on a fixture vault; the cwd is the fixture project",
  },
  {
    lua = [[_G.layout = function() return _G.read(_G.fx.lua .. "/_layouts/Dependencies.md") end
      _G.before = function(a, b) local s = _G.layout(); return s:find(a, 1, true) < s:find(b, 1, true) end
      _G.waivers = function() return _G.read(_G.fx.project .. "/.rules-waivers.json") or "" end]],
    note = "readers of the layout and of the waiver file",
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

---Type `:cmd` that asks first, answer the question with `answer` and check what it did.
local function ask(line, answer, expect, note)
  add({ input = ":" .. line .. "<CR>", note = ":" .. line .. ": " .. note })
  add({ wait = [[#_G.floats() > 0]], note = ":" .. line .. " asks first: the button dialog" })
  add({ keys = answer, note = "answer " .. answer })
  add({ wait = [[#_G.floats() == 0]], note = "the dialog is gone" })
  add({ wait = expect, note = ":" .. line .. " " .. note })
end

-- ---------- new ----------
cmd(
  "Rules new DEP Fresh rule here severity=critical --after=DEP-01",
  [[_G.bufpath() == vim.fs.normalize(_G.fx.lua .. "/_rules/DEP/DEP-04.md")
    and _G.buftext():find("severity: critical", 1, true) and _G.buftext():find("Fresh rule here", 1, true)
    and _G.before("{{rule DEP-01}}", "{{rule DEP-04}}") and _G.before("{{rule DEP-04}}", "## Extra")
    and _G.said("created DEP-04 in Dependencies.md", true)]],
  "makes the rule at the next free id (DEP-03 is retired, its id stays taken), places it and opens it"
)
cmd(
  "Rules new DEP",
  [[vim.api.nvim_buf_get_name(0) == "rules://rule-new" and vim.bo.filetype == "markdown"
    and _G.buftext():find("DEP", 1, true) ~= nil]],
  "opens the Markdown form, the family filled in"
)
add({ keys = "q", note = "q closes the form" })
add({
  expect = [[vim.api.nvim_buf_get_name(0) ~= "rules://rule-new" and _G.read(_G.fx.lua .. "/_rules/DEP/DEP-05.md") == nil]],
  note = "the form is gone and made nothing",
})

-- ---------- set ----------
add({
  lua = [[vim.cmd.edit(vim.fn.fnameescape(_G.fx.lua .. "/_rules/DEP/DEP-02.md"))
    _G.old = _G.read(_G.fx.lua .. "/_rules/DEP/DEP-02.md")]],
  note = "DEP-02 open in a buffer, as a person has it while changing it",
})
cmd(
  "Rules set DEP-02 severity=recommended title=Pin each dependency",
  [[_G.read(_G.fx.lua .. "/_rules/DEP/DEP-02.md")
      == _G.old:gsub("severity: critical", "severity: recommended"):gsub("Pin every dependency", "Pin each dependency")
    and _G.buftext():find("severity: recommended", 1, true) and _G.text():find("changed DEP-02", 1, true)
    and _G.said("reloaded", true)]],
  "changes the two parts, every other byte stays, the open buffer is reloaded",
  -- the reload is an `:edit` of the buffer: the runtime's markdown ftplugin undoes its maps with `sil! nunmap`,
  -- which sets v:errmsg (E31) without an error anybody sees
  true
)

-- ---------- move ----------
cmd(
  "Rules move DEP-04 --to=Dependencies.md#Extra",
  [[_G.before("## Extra", "{{rule DEP-04}}") and _G.before("{{rule DEP-02}}", "{{rule DEP-04}}")
    and _G.read(_G.fx.lua .. "/_rules/DEP/DEP-04.md"):find("Fresh rule here", 1, true)
    and _G.said("moved DEP-04 to Dependencies.md", true)]],
  "moves the rule's line into the other section; the rule's file stays"
)

-- ---------- retire / reinstate ----------
ask(
  "Rules retire DEP-04 --by=DEP-01",
  "n",
  [[_G.read(_G.fx.lua .. "/_rules/DEP/DEP-04.md") ~= nil and _G.read(_G.fx.lua .. "/_retired/DEP/DEP-04.md") == nil
    and _G.layout():find("{{rule DEP-04}}", 1, true) and not _G.text():find("retired DEP-04", 1, true)]],
  "keeps the rule when the answer is no"
)
ask(
  "Rules retire DEP-04 --by=DEP-01",
  "y",
  [[_G.read(_G.fx.lua .. "/_rules/DEP/DEP-04.md") == nil and _G.read(_G.fx.lua .. "/_retired/DEP/DEP-04.md") ~= nil
    and not _G.layout():find("DEP-04", 1, true) and _G.text():find("retired DEP-04", 1, true)
    and _G.said("put it back with :Rules reinstate DEP-04", true)]],
  "moves the file to _retired/ and out of the layout"
)
ask(
  "Rules reinstate DEP-03 --after=DEP-01",
  "y",
  [[_G.read(_G.fx.lua .. "/_rules/DEP/DEP-03.md") ~= nil and _G.read(_G.fx.lua .. "/_retired/DEP/DEP-03.md") == nil
    and _G.before("{{rule DEP-01}}", "{{rule DEP-03}}") and _G.said("reinstated DEP-03 in Dependencies.md", true)]],
  "brings the retired rule back at the place given"
)

-- ---------- waive / renew / unwaive ----------
cmd(
  "Rules waive DEP-01 reason=legacy code expires=2027-01-01 paths=main.lua",
  [[vim.json.decode(_G.waivers()) ~= nil and _G.waivers():find('"DEP-01"', 1, true)
    and _G.waivers():find("legacy code", 1, true) and _G.waivers():find("2027-01-01", 1, true)
    and _G.waivers():find("main.lua", 1, true) and _G.said("waived DEP-01 through 2027-01-01 in .rules-waivers.json", true)]],
  "writes the waiver with reason, last day and paths into the project"
)
add({ keys = ":Rules check --family=DEP<CR>", note = ":Rules check after the waiver" })
add({ expect = [[#vim.fn.getqflist() == 0]], note = "the waived finding no longer flags" })
add({ keys = ":tabclose<CR>" })
cmd(
  "Rules renew DEP-01 expires=2027-06-30",
  [[_G.waivers():find("2027-06-30", 1, true) and not _G.waivers():find("2027-01-01", 1, true)
    and _G.waivers():find("legacy code", 1, true) and _G.waivers():find("main.lua", 1, true)
    and _G.said("renewed the waiver of DEP-01 through 2027-06-30", true)]],
  "gives the waiver a new last day; reason and paths stay"
)
ask(
  "Rules unwaive DEP-01",
  "y",
  [[not _G.waivers():find("DEP-01", 1, true) and _G.said("removed the waiver of DEP-01 from .rules-waivers.json", true)]],
  "removes the waiver"
)
add({ keys = ":Rules check --family=DEP<CR>", note = ":Rules check after the unwaive" })
add({ expect = [[#vim.fn.getqflist() == 1]], note = "the finding flags again" })

return {
  id = "rules.bindings-write",
  title = "The changing :Rules commands of the nvim config write the rule, the layout and the waiver they name",
  task = "rules.nvim/abnahme-bindings-testblaetter",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = steps,
  manual = {
    "In the real config: the questions of :Rules retire, reinstate and unwaive come as ui.nvim's button dialog "
      .. "(No focused, n/y as keys); the sheet sees lib.nvim's copy of the kit",
    ":Rules new DEP (the form): fill in title and severity, <C-s> shows what would be made and asks, the rule is made",
  },
}
