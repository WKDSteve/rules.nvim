-- TESTS/contract_prewarm_spec.lua -- the commit of the engine (`engine.git` in the head of every document) in the
-- editor: asked in the background the moment an editor path asks for `editor_opts`, so no document of the editor waits
-- for git; the one document the editor prints as it is (`:Rules list --format=json`) waits for that lookup instead of
-- saying "unknown". Never at `setup` (SEC-22).
--
-- `vim.system` is a stand-in: its `wait()` throws (a document that waits for git fails the spec), and its callback is
-- called by the spec. A fresh `rules.contract` per case (the cache of the commit lives for the life of the module).
---@diagnostic disable: need-check-nil

---@class Spec.Start
---@field argv string[]
---@field on_exit fun(res: table)|nil

describe("rules.contract: engine.git in the editor", function()
  local saved_system, saved_contract
  ---@type Spec.Start[]
  local starts
  local contract, plugin_root

  before_each(function()
    saved_contract = package.loaded["rules.contract"]
    package.loaded["rules.contract"] = nil
    contract = require("rules.contract")
    local source = debug.getinfo(contract.editor_opts, "S").source:sub(2)
    plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(source, ":p")))))
    starts = {}
    saved_system = vim.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, _, on_exit)
      starts[#starts + 1] = { argv = argv, on_exit = on_exit }
      return {
        pid = 0,
        wait = function()
          error("the editor waited for " .. table.concat(argv, " "))
        end,
        kill = function() end,
        is_closing = function()
          return false
        end,
      }
    end
  end)

  after_each(function()
    vim.system = saved_system
    package.loaded["rules.contract"] = saved_contract
  end)

  ---@param sha string
  local function git_answers(sha)
    starts[1].on_exit({ code = 0, signal = 0, stdout = plugin_root .. "\n" .. sha .. "\n", stderr = "" })
  end

  it("an editor path starts the lookup in the background; its document does not wait and says unknown", function()
    contract.editor_opts()
    assert.are.equal(1, #starts)
    assert.is_function(starts[1].on_exit, "started with a callback, not waited for")
    assert.are.same({ "rev-parse", "--show-toplevel", "--short", "HEAD" }, vim.list_slice(starts[1].argv, 4))

    local head = contract.doc.head("list", plugin_root)
    assert.are.equal("unknown", head.engine.git)

    contract.editor_opts()
    assert.are.equal(1, #starts, "one lookup at a time")

    git_answers("abc1234")
    assert.are.equal("abc1234", contract.doc.head("list", plugin_root).engine.git)
    contract.editor_opts()
    assert.are.equal(1, #starts, "the answer is kept")
  end)

  it("the printed document waits for the running lookup and names the commit", function()
    local repo = require("lib.nvim.git.files").find(plugin_root)
    if vim.fn.executable("git") ~= 1 or not (repo and require("lib.nvim.fs.same_path")(repo.top, plugin_root)) then
      print("n/a  the plugin folder is no git checkout of its own here")
      return
    end
    contract.editor_opts()
    vim.defer_fn(function()
      git_answers("def5678")
    end, 30)
    contract.settle_engine(5000)
    assert.are.equal("def5678", contract.doc.head("list", plugin_root).engine.git)
    assert.are.equal(1, #starts)
  end)
end)
