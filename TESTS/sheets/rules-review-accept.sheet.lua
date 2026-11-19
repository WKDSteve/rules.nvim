-- Feature rules.review-accept: a person asks a model about the manual rule DEP-02 (:Rules agent DEP-02 --yes), opens
-- the proposals (:Rules review), puts the cursor on the one proposal and presses `a`. The verdict is written to
-- .rules-verdicts.json with the person and the commit the project is at (git rev-parse of the plugin, for real).
-- The model is a stub of ai.nvim's `ask` (the transport, like the network in a sheet: docs/SHEETS.md "Stubs in
-- sheets"), answering asynchronously like the real one; what a model says is the business of ai.nvim.

return {
  id = "rules.review-accept",
  title = "Accepting a model's proposal in :Rules review writes a verdict with the project's commit",
  feature = "rules.review-accept",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[_G.fx_setup = { agent = { scopes = { DEP = { include = { "**/*.lua" } } } } }
        dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")
        vim.g.rules_by = "sheet"]],
      note = "rules.setup as in the nvim config with an agent scope for DEP; the cwd is the fixture project",
    },
    {
      lua = [[_G.asked = {}
        local answer = vim.json.encode({
          results = {
            {
              rule = "DEP-02",
              verdict = "violation",
              checked = { "main.lua" },
              findings = { { file = "main.lua", line = 2, quote = "return x", why = "the dependency is not pinned" } },
            },
          },
        })
        package.loaded.ai = {
          ask = function(req, cb)
            _G.asked[#_G.asked + 1] = req
            vim.schedule(function()
              cb(true, { text = answer, provider = req.provider })
            end)
          end,
        }]],
      note = "the model: a stub of ai.nvim's ask that answers a violation of DEP-02 in main.lua line 2",
    },
    {
      lua = [[_G.git(_G.fx.project, { "init", "-q" })
        _G.git(_G.fx.project, { "add", "-A" })
        _G.git(_G.fx.project, { "commit", "-q", "-m", "base" })
        _G.head = vim.trim(_G.git(_G.fx.project, { "rev-parse", "HEAD" }))]],
      note = "the project is a git repository with one commit",
    },
    { keys = ":Rules agent DEP-02 --yes<CR>", note = "the person asks the model about DEP-02" },
    { wait = [[#_G.asked == 1 and _G.text():find("1 proposal", 1, true) ~= nil]], note = "the answer is in" },
    { keys = ":Rules review<CR>", note = "the person opens the proposals" },
    {
      expect = [[vim.bo.filetype == "rules-review" and _G.buftext():find("DEP-02", 1, true) ~= nil]],
      note = "the review shows the proposal for DEP-02",
    },
    { lua = [[vim.fn.search("DEP-02")]], note = "the cursor on the proposal" },
    { keys = "a", note = "accept it" },
    {
      expect = [[_G.said("DEP-02 accepted as violation by sheet", true)]],
      note = "the message says who accepted what",
    },
    {
      expect = [[(function()
          local doc = vim.json.decode(_G.read(_G.fx.project .. "/.rules-verdicts.json"))
          local text = vim.json.encode(doc)
          return text:find('"DEP-02"', 1, true) and text:find(_G.head, 1, true) and text:find('"sheet"', 1, true)
        end)()]],
      note = "the verdict file has DEP-02, the person and the commit the project is at",
    },
  },
}
