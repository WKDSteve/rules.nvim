-- TESTS/vault_ci_faults_spec.lua -- the CI workflow of a rules-vault (templates/rules-vault-ci.yml) turns red on each
-- of the faults it is there to catch. Its commands are run, as written, against small vaults; the shared code is
-- TESTS/helpers/vault_ci.lua, the vaults in good order are in TESTS/vault_ci_spec.lua.
---@diagnostic disable: need-check-nil
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local ci = dofile(here .. "/helpers/vault_ci.lua")
local tmp_dir, write, read, run_template, red = ci.tmp_dir, ci.write, ci.read, ci.run_template, ci.red
local make_vault, rule_text = ci.make_vault, ci.rule_text
local LINE_ENDINGS, DOCUMENTS, LOADS, ROUND_TRIP = ci.LINE_ENDINGS, ci.DOCUMENTS, ci.LOADS, ci.ROUND_TRIP

describe("the CI template of a rules-vault @spawn", function()
  if not ci.find_bash() then
    it("needs a bash", function()
      pending("no bash to run the workflow's steps in")
    end)
    return
  end

  describe("turns red", function()
    it("for a rule id that two files have, in one ruleset", function()
      local root = make_vault()
      write(root .. "/rulesets/lua/_rules/DEP/DEP-01-from-another-machine.md", rule_text("DEP-01"))
      local steps, by_name = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(steps), LOADS), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("duplicate rule id DEP-01", 1, true))
      assert.is_truthy(by_name[LOADS].out:find("FAILED: 1 load error(s)", 1, true))
    end)

    it("for a rule id that two rulesets have: only the load step sees it", function()
      local root = make_vault()
      write(root .. "/rulesets/native/_rules/DEP/DEP-02.md", rule_text("DEP-02"))
      local steps, by_name = run_template(root)
      -- each ruleset alone is in order: the documents and the round trip do not see the clash
      assert.are.same({ LOADS }, red(steps), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("duplicate rule id DEP-02", 1, true))
    end)

    it("for a live rule next to a retired rule with its id, in one ruleset (two machines, no conflict in git)", function()
      -- machine A made AAA-05 and retired it; machine B did not pull and made AAA-05 again: git merges both
      local root = make_vault()
      write(root .. "/rulesets/lua/_rules/AAA/AAA-05.md", rule_text("AAA-05"))
      write(root .. "/rulesets/lua/_retired/AAA/AAA-05.md", rule_text("AAA-05"))
      local steps, by_name = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(steps), LOADS), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("duplicate rule id AAA-05: ", 1, true), by_name[LOADS].out)
      assert.is_truthy(by_name[LOADS].out:find("lua/_retired/AAA/AAA-05.md (retired)", 1, true), by_name[LOADS].out)
      assert.is_truthy(by_name[LOADS].out:find("FAILED: 1 load error(s)", 1, true))
    end)

    it("for a live rule next to a retired one in another ruleset: only the load step sees it", function()
      local root = make_vault()
      write(root .. "/rulesets/native/_retired/DEP/DEP-02.md", rule_text("DEP-02"))
      local steps, by_name = run_template(root)
      assert.are.same({ LOADS }, red(steps), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("duplicate rule id DEP-02", 1, true))
    end)

    it("for a file under _rules/ that yields no rule: empty, no frontmatter, merge-conflict markers", function()
      for label, text in pairs({
        empty = "",
        ["no frontmatter"] = "#### `DEP-03`\n\nText.\n",
        ["conflict markers"] = "<<<<<<< HEAD\n" .. rule_text("DEP-03") .. "=======\n" .. rule_text("DEP-03") .. ">>>>>>> b\n",
      }) do
        local root = make_vault()
        write(root .. "/rulesets/lua/_rules/DEP/DEP-03.md", text)
        local steps, by_name = run_template(root)
        assert.is_truthy(vim.tbl_contains(red(steps), LOADS), label .. ": " .. vim.inspect(steps))
        assert.is_truthy(by_name[LOADS].out:find("DEP-03.md", 1, true), label)
        -- the reading documents and the round trip refuse it as well: none of the three is green on a rotten file
        assert.is_truthy(vim.tbl_contains(red(steps), DOCUMENTS), label .. ": " .. vim.inspect(steps))
        assert.is_truthy(vim.tbl_contains(red(steps), ROUND_TRIP), label .. ": " .. vim.inspect(steps))
      end
    end)

    it("is no fault for a README.md or a .gitkeep in _rules/, nor for a note in a folder of its own", function()
      local root = make_vault()
      write(root .. "/rulesets/lua/_rules/README.md", "# the rules\n")
      write(root .. "/rulesets/lua/_rules/DEP/.gitkeep", "")
      write(root .. "/rulesets/lua/notes/todo.md", "# todo\n")
      write(root .. "/rulesets/lua/_retired/.gitkeep", "")
      local steps = run_template(root)
      assert.are.same({}, red(steps), vim.inspect(steps))
    end)

    it("for a severity that is none", function()
      local root = make_vault()
      write(root .. "/rulesets/lua/_rules/DEP/DEP-02.md", rule_text("DEP-02", "urgent"))
      local steps, by_name = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(steps), LOADS), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("load error: ", 1, true))
    end)

    it("for a reading document that is not the one the layout makes", function()
      local root = make_vault()
      local path = root .. "/rulesets/lua/DEP.md"
      write(path, assert(read(path)) .. "edited by hand\n")
      local steps, by_name = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(steps), DOCUMENTS), vim.inspect(steps))
      assert.is_truthy(by_name[DOCUMENTS].out:find("stale", 1, true))
    end)

    -- the line-ending step needs no nvim: the CRLF cases run it alone
    it("for a CRLF file in the work tree, whatever the .gitattributes says", function()
      local root = make_vault()
      local path = root .. "/rulesets/lua/_rules/DEP/DEP-01.md"
      write(path, (assert(read(path)):gsub("\n", "\r\n")))
      local steps, by_name = run_template(root, { only = LINE_ENDINGS })
      assert.are.same({ LINE_ENDINGS }, red(steps), vim.inspect(steps))
      assert.is_truthy(by_name[LINE_ENDINGS].out:find("DEP-01.md", 1, true), by_name[LINE_ENDINGS].out)
      assert.is_truthy(by_name[LINE_ENDINGS].out:find("CRLF", 1, true))
    end)

    it("for a layout or a reading document with CRLF, not only for a rule file", function()
      for _, rel in ipairs({ "/rulesets/lua/_layouts/DEP.md", "/rulesets/lua/DEP.md" }) do
        local root = make_vault()
        write(root .. rel, (assert(read(root .. rel)):gsub("\n", "\r\n")))
        assert.are.same({ LINE_ENDINGS }, red((run_template(root, { only = LINE_ENDINGS }))), rel)
      end
    end)

    it("for a folder `rulesets/` that is not there", function()
      local root = tmp_dir()
      write(root .. "/.gitattributes", "* text=auto eol=lf\n")
      local steps = run_template(root)
      assert.is_truthy(#red(steps) >= 2, vim.inspect(steps))
      assert.is_truthy(vim.tbl_contains(red(steps), LINE_ENDINGS), "an unreadable folder is not a clean checkout")
    end)
  end)
end)
