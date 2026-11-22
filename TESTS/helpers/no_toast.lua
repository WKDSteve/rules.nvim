-- TESTS/helpers/no_toast.lua -- for the specs that read what a command says from a stubbed `vim.notify`.
--
-- Without ui.nvim, lib.nvim's popup notifier (`rules.util.notify`) shows a multi-line message in lib.nvim's own toast
-- (lib.nvim@161d963) instead of handing it to `vim.notify`; the toast wraps the text to its width. These specs check
-- what a message says, not where it is drawn: while `block()` holds, the toast cannot be loaded and the notifier hands
-- every message to `vim.notify`, whole, as it does where no toast can be shown.
local M = {}

local NAME = "lib.nvim.ui.kit.toast"

---@type { preload: function|nil, loaded: any }|nil
local saved

function M.block()
  if saved then
    return
  end
  saved = { preload = package.preload[NAME], loaded = package.loaded[NAME] }
  package.loaded[NAME] = nil
  package.preload[NAME] = function()
    error("no toast in this spec: its messages are read from vim.notify")
  end
end

function M.restore()
  if not saved then
    return
  end
  package.preload[NAME], package.loaded[NAME] = saved.preload, saved.loaded
  saved = nil
end

return M
