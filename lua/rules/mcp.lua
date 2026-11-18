---@module 'rules.mcp'
---@brief The read methods of `rules-export/1` as MCP tools, served by `lib.nvim.mcp.server` (`scripts/mcp.lua`).
---@description
--- Each tool is one method of `rules.api` (`lib.nvim.mcp.server.contract_tools`): the arguments are the method's
--- `params`, the answer is the document's canonical JSON, an error document is an `isError` result.
---
--- Only reads. The write door `ops` (`rules-ops/1`: new rules, edits, waivers) is left out on purpose: a waiver or a
--- changed rule written by the agent whose code the rule judges would let it excuse its own findings. A write tool
--- would need its own policy (who may, with which confirmation); until that exists there is none.

local M = {}

---The tools, by method of `rules.api`, with what the model reads about them.
---@type table<string, string>
M.TOOLS = {
  hello = "What this rules engine is: its version, the contract schema, its methods and limits.",
  list = "A page of rules in id order (id, family, severity, title). Filter by `family` and `severity`, "
    .. "page with `limit` and `offset`.",
  rule = "One rule by id (e.g. `LUA-12`): its text, its check and where it comes from.",
  next_id = "The next free rule id of a `family`.",
  sources = "The rulesets the rules were loaded from, with their counts.",
  waivers = "The waivers of a `project` (or of the configured one): which rule is waived where, why, until when.",
  rulesets = "The rulesets of the rules vault.",
}

---The server over the engine options `opts` (`rulesets`, `gates`, `vault`, `project`, `trust`; unset ones come from
---`rules.settings`, as for every caller of `rules.api`).
---@param opts? table
---@return Lib.Mcp.Server
function M.server(opts)
  opts = opts or {}
  local mcp_server = require("lib.nvim.mcp.server")
  local contract = require("rules.contract")
  local tools = mcp_server.contract_tools(require("rules.api"), {
    prefix = "rules_",
    methods = M.TOOLS,
    opts = function()
      return vim.deepcopy(opts)
    end,
  })
  return mcp_server.new({
    name = "rules.nvim",
    version = contract.ENGINE_VERSION,
    instructions = "Read-only tools over the rulesets of rules.nvim (rules-export/1): list rules, show one, "
      .. "the waivers of a project. Nothing here writes a rule or a waiver.",
    tools = tools,
  })
end

return M
