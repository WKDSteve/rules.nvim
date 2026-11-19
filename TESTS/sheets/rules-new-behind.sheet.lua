-- Feature rules.new-behind: the vault lives in git on more than one machine. Another machine pushed a commit, this one
-- fetched it but did not pull; a person makes a rule with :Rules new. The rule is made, and the message warns that the
-- vault is one commit behind its upstream (git rev-list of the plugin, read only, for real). The repositories (an
-- upstream, the vault as its clone, the other machine's clone) are made by the sheet (TESTS/sheets/_bindings.lua).

return {
  id = "rules.new-behind",
  title = ":Rules new warns when the vault is behind its upstream",
  feature = "rules.new-behind",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")]],
      note = "rules.setup as in the nvim config, on a fixture vault; the cwd is the fixture project",
    },
    {
      lua = [[local tmp, vault = _G.fx.tmp, _G.fx.vault
        local up, other = tmp .. "/upstream.git", tmp .. "/other"
        _G.git(vault, { "init", "-q" })
        _G.git(vault, { "add", "-A" })
        _G.git(vault, { "commit", "-q", "-m", "rules" })
        _G.git(tmp, { "clone", "-q", "--bare", vault, up })
        _G.git(vault, { "remote", "add", "origin", up })
        _G.git(vault, { "fetch", "-q", "origin" })
        _G.git(vault, { "branch", "-q", "--set-upstream-to=origin/main" })
        _G.git(tmp, { "clone", "-q", up, other })
        local f = assert(io.open(other .. "/README.md", "wb"))
        f:write("# Rules\n")
        f:close()
        _G.git(other, { "add", "README.md" })
        _G.git(other, { "commit", "-q", "-m", "readme" })
        _G.git(other, { "push", "-q", "origin", "main" })
        _G.git(vault, { "fetch", "-q", "origin" })]],
      note = "the vault is a clone; another machine pushed a commit that this one fetched and did not pull",
    },
    {
      keys = ":Rules new DEP Another rule severity=recommended<CR>",
      note = "the person makes a rule in the family DEP",
    },
    {
      wait = [[_G.read(_G.fx.lua .. "/_rules/DEP/DEP-04.md") ~= nil]],
      note = "the rule is made (DEP-03 is retired, its id stays taken)",
    },
    {
      expect = [[_G.text():find("created DEP-04", 1, true)
        and _G.said("the vault is 1 commit(s) behind its upstream: pull before you make a rule", true)]],
      note = "the message says it was made and warns that a pull is due",
    },
  },
}
