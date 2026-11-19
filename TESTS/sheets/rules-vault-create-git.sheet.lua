-- Feature rules.vault-create-git: a person makes a second vault for a team with :RulesVault create <dir> <name> --git.
-- Another vault is in use (the one of the config), so the plan question comes first; on yes the folder is made with
-- its files and the first ruleset, and git init runs in it for real (no remote, nothing pushed). The sheet reads the
-- message and the .git folder.

return {
  id = "rules.vault-create-git",
  title = ":RulesVault create --git makes a vault with a git repository of its own",
  feature = "rules.vault-create-git",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")]],
      note = "rules.setup as in the nvim config, on a fixture vault; the cwd is the fixture project",
    },
    {
      input = ":RulesVault create team-vault demo --git<CR>",
      note = "the person makes a vault named team-vault with the ruleset demo, with git",
    },
    { wait = [[_G.dialog()]], note = "another vault is in use: the plan question" },
    {
      expect = [[_G.buftext():find("git init in the folder (--git)", 1, true) ~= nil]],
      note = "the plan says that git init will run, without a remote",
    },
    { keys = "y", note = "answer yes" },
    {
      wait = [[vim.fn.isdirectory(_G.fx.project .. "/team-vault/.git") == 1
        and _G.read(_G.fx.project .. "/team-vault/.rules.json") ~= nil]],
      note = "the vault is made and is a git repository",
    },
    {
      expect = [[vim.fn.isdirectory(_G.fx.project .. "/team-vault/rulesets/demo/_rules") == 1
        and _G.said("git init done (no remote)", true)]],
      note = "the first ruleset is there, and the message says git init ran without a remote",
    },
  },
}
