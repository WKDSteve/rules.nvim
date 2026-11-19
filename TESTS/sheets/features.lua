-- TESTS/sheets/features.lua -- the catalog of the functionalities of rules.nvim that start a process (git above all),
-- read by testing.nvim as data (docs/SHEETS.md "Feature sheets and the catalog", docs/PERF.md). Each one has a feature
-- sheet beside this file, or says with `perf` why `testing perf` does not measure it through one.
-- The functionalities that start nothing (list, show, check, new, set, waive, ...) are covered by the binding sheets
-- (rules-bindings-*.sheet.lua) and are not listed here.

return {
  {
    id = "rules.gate-diff",
    title = "A gate narrowed to the files changed since a ref (git diff and the untracked files)",
    surface = { "command:Rules gate", "config:gates" },
    docs = "docs/BINDINGS.md",
  },
  {
    id = "rules.vault-status",
    title = ":RulesVault says where the vault comes from, its rulesets and whether git has uncommitted changes in it",
    surface = { "command:RulesVault", "config:vault" },
    docs = "docs/BINDINGS.md",
  },
  {
    id = "rules.vault-create-git",
    title = ":RulesVault create --git makes a vault and a git repository in it (no remote)",
    surface = { "command:RulesVault create" },
    docs = "docs/BINDINGS.md",
  },
  {
    id = "rules.new-behind",
    title = ":Rules new warns before it makes a rule when the vault is behind its upstream (a pull is due)",
    surface = { "command:Rules new", "config:vault" },
    docs = "docs/BINDINGS.md",
  },
  {
    id = "rules.review-accept",
    title = "Accepting a proposal of :Rules agent in :Rules review writes a verdict with the commit of the project",
    surface = { "command:Rules agent", "command:Rules review", "config:agent" },
    docs = "docs/AGENT.md",
  },
  {
    id = "rules.list-json",
    title = ":Rules list --format=json prints the rules.list document of the machine contract, its head names the "
      .. "commit of the engine",
    surface = { "command:Rules list" },
    docs = "docs/CONTRACT.md",
  },
  {
    id = "rules.vault-clipboard",
    title = ":RulesVault clipboard|cdx puts a path, a link or a prompt into the system clipboard",
    surface = { "command:RulesVault clipboard", "command:RulesVault cdx" },
    docs = "docs/BINDINGS.md",
    perf = "skip:starts a process only without a clipboard provider (lib.nvim falls back to pbcopy, wl-copy, xclip "
      .. "or Set-Clipboard); with one the editor's provider copies, the sheet rules.bindings-vault proves the copy",
  },
  {
    id = "rules.contract-host",
    title = "scripts/rules.lua and scripts/mcp.lua answer other apps with the documents of the machine contract",
    surface = { "script:scripts/rules.lua", "script:scripts/mcp.lua" },
    docs = "docs/CONTRACT.md",
    perf = "skip:the hosts run as a child nvim -l of another program; the trace of testing perf does not follow into "
      .. "it, and their git start is the one rules.list-json measures in the editor",
  },
}
