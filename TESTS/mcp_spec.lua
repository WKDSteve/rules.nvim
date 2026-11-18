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
end)
