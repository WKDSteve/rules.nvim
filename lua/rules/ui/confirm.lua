---@module 'rules.ui.confirm'
---@brief The question of `:Rules` before a step that is not undone by a keystroke (retire, create from the form).
---@description
--- `lib.nvim.ui.dialog`: the themed button dialog every plugin of the family uses (the shared helper: a backend is
--- chosen, a native question when no float can open). It answers by callback, once, never before the call returns.
--- The first choice is the one the dialog starts on, so it is always the harmless one.
---
--- `M.choose` is the seam the specs replace: a spec that asks a question answers it itself, the dialog never opens.
--- `M.yesno` goes through the same seam when it was replaced, and through `dialog.yesno` otherwise.

local M = {}

---@param question string
---@param choices string[]  the first is the harmless one
---@param cb fun(index: integer|nil)
local function default_choose(question, choices, cb)
  require("lib.nvim.ui.dialog").choose(question, choices, 1, function(index)
    cb(index > 0 and index or nil)
  end)
end

---A question with several answers. `cb` gets the index of the answer (1-based), `nil` when the dialog was dismissed
---(`<Esc>`, `q`) or could not open: not an answer, nothing happens.
---@type fun(question: string, choices: string[], cb: fun(index: integer|nil))
M.choose = default_choose

---Yes or no, "No" first and focused, `n`/`y` are keys. `cb(true)` only for the yes.
---@param question string
---@param yes_label string  shown as "Yes, <yes_label>"
---@param cb fun(accepted: boolean)
function M.yesno(question, yes_label, cb)
  if M.choose ~= default_choose then
    -- a spec replaced the seam: it answers the question itself
    M.choose(question, { "No", "Yes, " .. yes_label }, function(index)
      cb(index == 2)
    end)
    return
  end
  require("lib.nvim.ui.dialog").yesno(question, yes_label, cb)
end

return M
