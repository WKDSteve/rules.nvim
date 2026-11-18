-- TESTS/mcp_spec.lua -- `rules.mcp`: the read methods of `rules-export/1` as MCP tools (lib.nvim.mcp.server).
---@diagnostic disable: need-check-nil

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

describe("rules.mcp", function()
  local root = vim.fn.tempname() .. "/Checklists"
  write_raw(
    root .. "/DEP.md",
    table.concat({
      "# Dependencies",
      "",
      "### `DEP-01` — one",
      "",
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      'check = { type = "grep", pattern = "foo" },',
      "```",
      "",
      "Text of one.",
      "",
    }, "\n")
  )
  local server = require("rules.mcp").server({ rulesets = { root } })

  ---@param msg table
  ---@return table
  local function send(msg)
    return vim.json.decode(server:dispatch(vim.json.encode(msg)))
  end

  it("lists read tools only, without the write door", function()
    local res = send({ jsonrpc = "2.0", id = 1, method = "tools/list" })
    local names = {}
    for _, t in ipairs(res.result.tools) do
      names[t.name] = t
    end
    assert.is_truthy(names.rules_list and names.rules_rule and names.rules_waivers)
    assert.is_nil(names.rules_ops)
    assert.are.equal("id", names.rules_rule.inputSchema.required[1])
  end)

  it("answers rules_rule with the rule document, and an unknown id as an error result", function()
    local res = send({
      jsonrpc = "2.0",
      id = 2,
      method = "tools/call",
      params = { name = "rules_rule", arguments = { id = "DEP-01" } },
    })
    assert.is_nil(res.result.isError)
    local doc = vim.json.decode(res.result.content[1].text)
    assert.are.equal("rules.rule", doc.kind)
    assert.is_truthy(res.result.content[1].text:find("DEP-01", 1, true))
    res = send({
      jsonrpc = "2.0",
      id = 3,
      method = "tools/call",
      params = { name = "rules_rule", arguments = { id = "DEP-99" } },
    })
    assert.is_true(res.result.isError)
  end)

  it("serves scripts/mcp.lua as a real stdio process to the lib.nvim MCP client", function()
    if not vim.env.LIB_NVIM_DIR or vim.env.LIB_NVIM_DIR == "" then
      pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
    end
    -- the client's VimLeavePre group is made by its first client; a spec that made it takes it away again
    local had_group = pcall(vim.api.nvim_get_autocmds, { group = "lib.nvim.mcp" })
    local contract_file = vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1]
    local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(contract_file))))
    local c = require("lib.nvim.mcp").client({
      id = "rules-mcp-stdio-spec",
      cmd = {
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-n",
        "-l",
        plugin_root .. "/scripts/mcp.lua",
        "--ruleset=" .. root,
      },
      -- NVIM cleared: inside the runner it names the parent editor
      env = { NVIM = "", NVIM_LISTEN_ADDRESS = "", LIB_NVIM_DIR = vim.env.LIB_NVIM_DIR },
      timeout_ms = 20000,
    })
    local function ask(fn)
      local done, a, b = false, nil, nil
      fn(function(x, y)
        done, a, b = true, x, y
      end)
      vim.wait(25000, function()
        return done
      end, 10)
      return a, b
    end
    local tools, err = ask(function(cb)
      c:list_tools(cb)
    end)
    assert.is_nil(err)
    assert.are.equal(7, #tools)
    assert.are.equal("rules.nvim", c:server().serverInfo.name)
    local res = ask(function(cb)
      c:call_tool("rules_rule", { id = "DEP-01" }, cb)
    end)
    assert.is_falsy(res.isError)
    assert.are.equal("rules.rule", vim.json.decode(res.content[1].text).kind)
    require("lib.nvim.mcp").forget("rules-mcp-stdio-spec")
    if not had_group then
      pcall(vim.api.nvim_del_augroup_by_name, "lib.nvim.mcp")
    end
  end)
end)
