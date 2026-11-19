-- Feature rules.gate-diff: a person works on a change in a project under git and runs the review gate on what the
-- change touches only: :Rules gate review --diff=HEAD. The plugin asks git for the changed files (git diff
-- --name-only) and the new ones (git ls-files --others), for real. The project's old finding in main.lua stays out of
-- the report; the edited file and the new file are in it.

return {
  id = "rules.gate-diff",
  title = ":Rules gate --diff reports the findings of the changed and the new files only",
  feature = "rules.gate-diff",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")]],
      note = "rules.setup as in the nvim config (gate review = DEP); the cwd is the fixture project",
    },
    {
      lua = [[local p = _G.fx.project
        vim.fn.writefile({ "local y = 2", "return y" }, p .. "/other.lua")
        _G.git(p, { "init", "-q" })
        _G.git(p, { "add", "-A" })
        _G.git(p, { "commit", "-q", "-m", "base" })]],
      note = "the project in git: main.lua (an old FIXME) and other.lua committed",
    },
    {
      lua = [[vim.cmd.edit(vim.fn.fnameescape(_G.fx.project .. "/other.lua"))
        vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- FIXME: edited" })
        vim.cmd("silent write")
        vim.fn.writefile({ "-- FIXME: new" }, _G.fx.project .. "/new.lua")]],
      note = "the change: other.lua edited and written, new.lua made and not added",
    },
    { keys = ":Rules gate review --diff=HEAD<CR>", note = "the person runs the gate on the change" },
    {
      expect = [[vim.bo.filetype == "rulesreport" and #vim.fn.getqflist() == 2
        and _G.qftext():find("[DEP-01] -- FIXME: edited", 1, true)
        and _G.qftext():find("[DEP-01] -- FIXME: new", 1, true)
        and not _G.buftext():find("main.lua", 1, true)]],
      note = "the report and the quickfix list have the edited and the new file, not main.lua",
    },
    { keys = ":tabclose<CR>", note = "close the report" },
  },
}
