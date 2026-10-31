-- TESTS/vault_ci_spec.lua -- the CI workflow of a rules-vault (templates/rules-vault-ci.yml): its commands are run, as
-- written, against small vaults. This file: the steps of the template, the vaults in good order, that the CI only
-- reads, and the opt-in run against the real rulesets. The faults the CI is there to catch are in
-- TESTS/vault_ci_faults_spec.lua, the real git checkouts in TESTS/vault_ci_checkout_spec.lua; the shared code is
-- TESTS/helpers/vault_ci.lua.
--
-- A second look at the real rulesets (571 rules, too slow and too big for a spec) is opt-in:
--
--   RULES_REAL_LUA=<Checklists of wkdbook-Lua> RULES_REAL_NATIVE=<Checklists of wkdbook-native> \
--     nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua run . --file vault_ci_spec
--
-- (PowerShell: set `$env:RULES_REAL_LUA` and `$env:RULES_REAL_NATIVE` first.) The two folders are copied to a temporary
-- vault (`rulesets/lua`, `rulesets/native`) before anything runs; nothing is ever written into them.
---@diagnostic disable: need-check-nil
local fswalk = require("rules.engine.fswalk")
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local ci = dofile(here .. "/helpers/vault_ci.lua")
local tmp_dir, write, read, run_template, red = ci.tmp_dir, ci.write, ci.read, ci.run_template, ci.red
local LINE_ENDINGS, DOCUMENTS, LOADS, ROUND_TRIP = ci.LINE_ENDINGS, ci.DOCUMENTS, ci.LOADS, ci.ROUND_TRIP

describe("the CI template of a rules-vault @spawn", function()
  local template = assert(read(ci.TEMPLATE))

  if not ci.find_bash() then
    it("needs a bash", function()
      pending("no bash to run the workflow's steps in")
    end)
    return
  end

  it("takes the steps out of the file: the four of the workflow, in order", function()
    local names = {}
    for _, step in ipairs(ci.steps_of(template)) do
      names[#names + 1] = step.name
    end
    assert.are.same({ LINE_ENDINGS, DOCUMENTS, LOADS, ROUND_TRIP }, names)
  end)

  it("runs one step alone when asked, and refuses a step the template does not have", function()
    local steps = run_template(ci.make_vault(), { only = LINE_ENDINGS })
    assert.are.same(
      { LINE_ENDINGS },
      vim.tbl_map(function(step)
        return step.name
      end, steps)
    )
    assert.has_error(function()
      run_template(tmp_dir(), { only = "no such step" })
    end)
  end)

  describe("a vault in good order", function()
    it("is green in every step, on both rulesets", function()
      local steps, by_name = run_template(ci.make_vault())
      assert.are.same({}, red(steps), vim.inspect(steps))
      assert.is_truthy(by_name[DOCUMENTS].out:find("rulesets/lua", 1, true))
      assert.is_truthy(by_name[DOCUMENTS].out:find("rulesets/native", 1, true))
      assert.is_truthy(by_name[LOADS].out:find("3 rule(s) in 3 file(s), 2 family(ies), 2 ruleset(s)", 1, true))
      assert.is_truthy(by_name[LOADS].out:find("ok: every ruleset loads without errors", 1, true))
      assert.is_truthy(by_name[ROUND_TRIP].out:find("rule files: 3, refused: 0, failed: 0", 1, true))
    end)

    it("is green for a vault with a ruleset that has no rule yet (what :RulesVault create makes)", function()
      local root = tmp_dir()
      write(root .. "/.gitattributes", "* text=auto eol=lf\n")
      write(root .. "/rulesets/default/_rules/.gitkeep", "")
      write(root .. "/rulesets/default/_layouts/.gitkeep", "")
      local steps, by_name = run_template(root)
      assert.are.same({}, red(steps), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("0 rule(s)", 1, true))
    end)

    it("is green for the vault `:RulesVault create` really makes, in all four steps", function()
      local scaffold = require("rules.vault_scaffold")
      local root = tmp_dir() .. "/vault"
      local plan = assert(scaffold.plan({ root = root, name = "default" }))
      assert(scaffold.create(plan))
      assert.is_truthy(read(root .. "/rulesets/default/_rules/.gitkeep"))
      local steps, by_name = run_template(root)
      assert.are.same({}, red(steps), vim.inspect(steps))
      assert.are.equal(4, #steps)
      assert.is_truthy(by_name[LOADS].out:find("0 rule(s) in 0 file(s), 0 family(ies), 1 ruleset(s)", 1, true))
      assert.is_truthy(by_name[ROUND_TRIP].out:find("rule files: 0, refused: 0, failed: 0", 1, true))
    end)

    it("is green for a rule made in that vault, and red once the rule is retired and made again", function()
      local scaffold = require("rules.vault_scaffold")
      local root = tmp_dir() .. "/vault"
      assert(scaffold.create(assert(scaffold.plan({ root = root, name = "default" }))))
      write(root .. "/rulesets/default/_rules/AAA/AAA-01.md", ci.rule_text("AAA-01"))
      assert.are.same({}, red((run_template(root))))
      write(root .. "/rulesets/default/_retired/AAA/AAA-01.md", ci.rule_text("AAA-01"))
      assert.is_truthy(vim.tbl_contains(red((run_template(root))), LOADS))
    end)
  end)

  describe("only reads", function()
    it("leaves every file of the vault as it was, whatever the verdict", function()
      local root = ci.make_vault()
      write(root .. "/rulesets/native/_rules/DEP/DEP-02.md", ci.rule_text("DEP-02"))
      local function snapshot()
        local out = {}
        for _, file in ipairs(fswalk.files(root)) do
          out[file:sub(#root + 2)] = read(file)
        end
        return out
      end
      local before = snapshot()
      run_template(root)
      assert.are.same(before, snapshot())
    end)
  end)

  -- opt-in: the real rulesets of the WKDBooks, copied into a vault; see the header of this file
  describe("the real rulesets", function()
    local lua_dir, native_dir = vim.env.RULES_REAL_LUA, vim.env.RULES_REAL_NATIVE
    local have = lua_dir and lua_dir ~= "" and native_dir and native_dir ~= ""

    ---@param from string
    ---@param to string
    local function copy_tree(from, to)
      from = (from:gsub("\\", "/")):gsub("/+$", "")
      for _, file in ipairs(fswalk.files(from)) do
        local dest = to .. "/" .. file:sub(#from + 2)
        vim.fn.mkdir(vim.fs.dirname(dest), "p")
        assert((vim.uv or vim.loop).fs_copyfile(file, dest), "could not copy " .. file)
      end
    end

    -- no case without the two folders: a skipped case would turn every ordinary run into a "partial" one
    if not have then
      return
    end

    it("are green in every step, and red once an id is made twice", function()
      local root = tmp_dir()
      write(root .. "/.gitattributes", "* text=auto eol=lf\n")
      copy_tree(lua_dir, root .. "/rulesets/lua")
      copy_tree(native_dir, root .. "/rulesets/native")
      local steps, by_name = run_template(root)
      assert.are.same({}, red(steps), vim.inspect(steps))
      print(
        ("real rulesets: %s | %s"):format(
          vim.trim(by_name[LOADS].out:match("[^\n]*rule%(s%)[^\n]*") or "?"),
          (by_name[ROUND_TRIP].out:match("rule files:[^\n]*") or "?")
        )
      )

      -- the same vault with one id made a second time, the way a second machine would
      local first = vim.fn.glob(root .. "/rulesets/lua/_rules/*/*.md", false, true)[1]
      local text = assert(read(first))
      local id = assert(text:match("\nid:%s*(%S+)"))
      write(root .. "/rulesets/native/_rules/ZZZ/" .. id .. ".md", text)
      local again = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(again), LOADS), vim.inspect(again))
    end)
  end)
end)
