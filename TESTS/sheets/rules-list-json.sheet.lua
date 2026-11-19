-- Feature rules.list-json: a script or another plugin reads the rules of the editor as the machine contract with
-- :Rules list --format=json (captured as `:execute` captures it). The head of the document names the engine, the
-- commit of the plugin checkout among it: the plugin asks git for it once (git rev-parse in its own folder, for real),
-- then from its cache. The sheet compares it with what git says about that folder.

return {
  id = "rules.list-json",
  title = ":Rules list --format=json prints the rules.list document with the engine's commit in its head",
  feature = "rules.list-json",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")]],
      note = "rules.setup as in the nvim config, on a fixture vault; the cwd is the fixture project",
    },
    {
      lua = [[local file = vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1]
        local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(file))))
        local done = vim.system({ "git", "-C", root, "rev-parse", "--show-toplevel", "--short", "HEAD" }, { text = true })
          :wait(30000)
        local top, sha = (done.stdout or ""):match("^([^\n]+)\n(%x+)")
        local same = top and _G.real(top):lower() == _G.real(root):lower()
        _G.want_git = (done.code == 0 and same) and sha or "unknown"]],
      note = "what git says about the plugin's folder: its short commit, or unknown when it is no checkout of its own",
    },
    {
      lua = [[_G.json = vim.json.decode(vim.trim(vim.fn.execute("Rules list --format=json")))]],
      note = "the script captures :Rules list --format=json",
    },
    {
      expect = [[_G.json.kind == "rules.list" and _G.json.plugin == "rules.nvim" and _G.json.total == 2
        and _G.json.items[1].id == "DEP-01" and _G.json.engine.git == _G.want_git]],
      note = "the rules.list document with both rules; its head names the plugin's commit",
    },
    {
      lua = [[_G.json = vim.json.decode(vim.trim(vim.fn.execute("Rules list --format=json --family=DEP --severity=critical")))]],
      note = "asked again, narrowed",
    },
    {
      expect = [[_G.json.total == 1 and _G.json.items[1].id == "DEP-02" and _G.json.engine.git == _G.want_git]],
      note = "one rule; the head is the same (from the cache, no second git)",
    },
  },
}
