-- TESTS/helpers/no_toast.lua -- for the specs that read what a command says from a stubbed `vim.notify`.
--
-- Without ui.nvim, lib.nvim's popup notifier (`rules.util.notify`) shows a multi-line message in lib.nvim's own toast
-- (lib.nvim@161d963) instead of handing it to `vim.notify`; the toast wraps the text to its width. These specs check
-- what a message says, not where it is drawn: while `block()` holds, lib.nvim's official switch
-- (`popup.setup({ fallback_toast = false })`) is off and the notifier hands every message to `vim.notify`, whole.
local M = {}

local blocked = false

---@return table popup lib.nvim.notify.popup
local function popup()
  return (require("lib.nvim.notify.popup"))
end

function M.block()
  if blocked then
    return
  end
  blocked = true
  popup().setup({ fallback_toast = false })
end

function M.restore()
  if not blocked then
    return
  end
  blocked = false
  popup().setup({ fallback_toast = true })
end

return M
