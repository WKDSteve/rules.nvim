-- TESTS/confirm_dialog_spec.lua -- `rules.ui.confirm` asks through lib.nvim's shared dialog: a yes/no through
-- `dialog.yesno`, a list through `dialog.choose` (0 is a dismissal, nil to the caller), and a spec's replaced
-- `choose` still answers a yes/no.

---@diagnostic disable: duplicate-set-field, need-check-nil
-- Why: the spec replaces the dialog's functions and the seam with test doubles on purpose.

describe("rules.ui.confirm", function()
  local confirm = require("rules.ui.confirm")
  local dialog = require("lib.nvim.ui.dialog")
  local orig = { yesno = dialog.yesno, choose = dialog.choose, seam = confirm.choose }

  after_each(function()
    dialog.yesno, dialog.choose, confirm.choose = orig.yesno, orig.choose, orig.seam
  end)

  it("asks a yes/no through dialog.yesno", function()
    local seen
    dialog.yesno = function(question, label, cb)
      seen = { question, label, cb }
    end
    local got = {}
    confirm.yesno("Retire it?", "retire", function(yes)
      got[#got + 1] = yes
    end)
    assert.are.same({ "Retire it?", "retire" }, { seen[1], seen[2] })
    seen[3](true)
    seen[3](false)
    assert.are.same({ true, false }, got)
  end)

  it("asks a list through dialog.choose with the first choice focused; 0 is a dismissal", function()
    local call
    dialog.choose = function(question, choices, default, cb)
      call = { question = question, choices = choices, default = default, cb = cb }
    end
    local got = {}
    confirm.choose("Which?", { "Keep", "Drop" }, function(i)
      got[#got + 1] = i == nil and "nil" or i
    end)
    assert.are.equal(1, call.default)
    call.cb(2)
    call.cb(0)
    assert.are.same({ 2, "nil" }, got)
  end)

  it("lets a replaced choose answer a yes/no without opening a dialog", function()
    dialog.yesno = function()
      error("must not open")
    end
    confirm.choose = function(_, choices, cb)
      assert.are.same({ "No", "Yes, go" }, choices)
      cb(2)
    end
    local got
    confirm.yesno("Go?", "go", function(yes)
      got = yes
    end)
    assert.is_true(got)
  end)
end)
