-- Feature rules.vault-status: a person types :RulesVault in a project while the vault of the config is a git
-- repository, as the real one is. The message names the vault, where it was named and its rulesets, and what git says:
-- first a rule file changed and not committed, then clean after the commit. The git of the plugin runs for real
-- (rev-parse and status, read only); the fixture repository is made by the sheet (TESTS/sheets/_bindings.lua).

local said_status = [[_G.text():find("Vault: " .. _G.fx.vault .. " (from setup({ vault = ... }))", 1, true)
  and _G.text():find("rulesets: lua, native", 1, true)]]

return {
  id = "rules.vault-status",
  title = ":RulesVault tells whether the vault has uncommitted changes in git",
  feature = "rules.vault-status",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")]],
      note = "rules.setup as in the nvim config, on a fixture vault; the cwd is the fixture project",
    },
    {
      lua = [[_G.git(_G.fx.vault, { "init", "-q" })
        _G.git(_G.fx.vault, { "add", "-A" })
        _G.git(_G.fx.vault, { "commit", "-q", "-m", "rules" })
        local f = assert(io.open(_G.fx.lua .. "/_rules/DEP/DEP-02.md", "ab"))
        f:write("One more line.\n")
        f:close()]],
      note = "the vault is a git repository; DEP-02.md is changed and not committed",
    },
    { keys = ":RulesVault<CR>", note = "the person asks which vault is in use" },
    {
      expect = said_status .. [[ and _G.said("git: 1 uncommitted path(s)", true)]],
      note = "the vault, its rulesets and the one uncommitted path",
    },
    {
      lua = [[_G.git(_G.fx.vault, { "commit", "-q", "-a", "-m", "DEP-02" })]],
      note = "the change is committed",
    },
    { keys = ":RulesVault<CR>", note = "asked again" },
    {
      expect = said_status .. [[ and _G.said("git: clean", true)]],
      note = "now git is clean",
    },
  },
}
