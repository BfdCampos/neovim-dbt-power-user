-- Specs for run_results.json -> quickfix translation.

local manifest = require("dbt-power-user.manifest")
local quickfix = require("dbt-power-user.quickfix")

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local fixture = repo_root .. "/tests/fixtures/jaffle-shop"

-- Swap in synthetic results while keeping the real manifest, so unique_ids still resolve
-- against real nodes. The fixture's own run_results.json is whatever the last real dbt
-- invocation against it happened to run (its node count and args.which change every time
-- someone re-runs dbt here, including this plugin's own end-to-end checks) -- assert it's
-- all-clean, never an exact count, or this suite breaks every time the fixture is rebuilt.
local function with_results(results, fn)
  local original = manifest.load_run_results
  manifest.load_run_results = function()
    return { results = results }
  end
  local ok, err = pcall(fn)
  manifest.load_run_results = original
  assert(ok, err)
end

local function result(status, unique_id, message)
  return { status = status, unique_id = unique_id, message = message, failures = vim.NIL }
end

describe("quickfix.is_failure", function()
  it("treats dbt's failing statuses as failures", function()
    assert.is_true(quickfix.is_failure("error"))
    assert.is_true(quickfix.is_failure("fail"))
    assert.is_true(quickfix.is_failure("runtime error"))
    assert.is_true(quickfix.is_failure("skipped"))
    assert.is_true(quickfix.is_failure("partial success"))
  end)

  it("treats success, pass and warn as clean", function()
    assert.is_false(quickfix.is_failure("success"))
    assert.is_false(quickfix.is_failure("pass"))
    assert.is_false(quickfix.is_failure("warn"))
  end)

  it("is case insensitive", function()
    assert.is_true(quickfix.is_failure("Runtime Error"))
    assert.is_false(quickfix.is_failure("SUCCESS"))
  end)

  it("treats a missing or non-string status as clean", function()
    assert.is_false(quickfix.is_failure(nil))
    assert.is_false(quickfix.is_failure(vim.NIL))
    assert.is_false(quickfix.is_failure(""))
    assert.is_false(quickfix.is_failure("no such status"))
  end)
end)

describe("quickfix.entries", function()
  it("returns no entries for the real all-passing run", function()
    local results = manifest.load_run_results(fixture)
    assert.is_true(#results.results > 0)
    for _, item in ipairs(results.results) do
      assert.is_false(quickfix.is_failure(item.status))
    end
    assert.are.same({}, quickfix.entries(fixture))
  end)

  it("returns nil when the project has no run_results.json", function()
    assert.is_nil(quickfix.entries(repo_root .. "/tests"))
  end)

  it("builds an entry for a failing model from its real manifest path", function()
    with_results({
      result("success", "model.jaffle_shop.stg_customers", vim.NIL),
      result("error", "model.jaffle_shop.customers", "Binder Error: no such column"),
    }, function()
      local entries = quickfix.entries(fixture)
      assert.are.equal(1, #entries)
      assert.are.same({
        filename = fixture .. "/models/marts/customers.sql",
        lnum = 1,
        col = 1,
        text = "Binder Error: no such column",
        type = "E",
      }, entries[1])
    end)
  end)

  it("resolves a failing test node, which is absent from the graph projection", function()
    local unique_id = "test.jaffle_shop.not_null_customers_customer_id.5c9bf9911d"
    assert.is_nil(manifest.graph(fixture).nodes[unique_id])

    with_results({ result("fail", unique_id, "Got 3 results, configured to fail if != 0") }, function()
      local entries = quickfix.entries(fixture)
      assert.are.equal(1, #entries)
      assert.are.equal(fixture .. "/models/marts/customers.yml", entries[1].filename)
      assert.are.equal("Got 3 results, configured to fail if != 0", entries[1].text)
    end)
  end)

  it("falls back to the status when the message is JSON null", function()
    with_results({ result("skipped", "model.jaffle_shop.orders", vim.NIL) }, function()
      local entries = quickfix.entries(fixture)
      assert.are.equal("skipped", entries[1].text)
    end)
  end)

  it("flattens a multi-line dbt message onto one quickfix line", function()
    local message = "Database Error in model customers\n  Binder Error: no such column\n\n  line 12"
    with_results({ result("runtime error", "model.jaffle_shop.customers", message) }, function()
      local entries = quickfix.entries(fixture)
      assert.are.equal(
        "Database Error in model customers Binder Error: no such column line 12",
        entries[1].text
      )
    end)
  end)

  it("keeps every failing status and drops every clean one", function()
    with_results({
      result("success", "model.jaffle_shop.customers", vim.NIL),
      result("pass", "model.jaffle_shop.orders", vim.NIL),
      result("warn", "model.jaffle_shop.order_items", "16 rows warned"),
      result("error", "model.jaffle_shop.stg_customers", "e"),
      result("fail", "model.jaffle_shop.stg_orders", "f"),
      result("skipped", "model.jaffle_shop.stg_products", "s"),
      result("runtime error", "model.jaffle_shop.stg_locations", "r"),
      result("partial success", "model.jaffle_shop.stg_supplies", "p"),
    }, function()
      assert.are.equal(5, #quickfix.entries(fixture))
    end)
  end)

  it("keeps an unresolvable unique_id as a text-only entry", function()
    with_results({ result("error", "model.other_project.ghost", "boom") }, function()
      local entries = quickfix.entries(fixture)
      assert.are.equal(1, #entries)
      assert.is_nil(entries[1].filename)
      assert.are.equal("model.other_project.ghost: boom", entries[1].text)
    end)
  end)

  it("sorts entries by filename", function()
    with_results({
      result("error", "model.jaffle_shop.stg_orders", "b"),
      result("error", "model.jaffle_shop.customers", "a"),
      result("error", "model.jaffle_shop.orders", "c"),
    }, function()
      local entries = quickfix.entries(fixture)
      local names = {}
      for _, entry in ipairs(entries) do
        names[#names + 1] = entry.filename
      end
      assert.are.same({
        fixture .. "/models/marts/customers.sql",
        fixture .. "/models/marts/orders.sql",
        fixture .. "/models/staging/stg_orders.sql",
      }, names)
    end)
  end)
end)

describe("quickfix.populate_from_run_results", function()
  before_each(function()
    vim.fn.setqflist({}, "r")
  end)

  it("replaces the list with the failing entries and fires QuickFixCmdPost", function()
    local fired = false
    local autocmd = vim.api.nvim_create_autocmd("QuickFixCmdPost", {
      pattern = "*",
      callback = function()
        fired = true
      end,
    })

    with_results({
      result("error", "model.jaffle_shop.customers", "Binder Error"),
      result("success", "model.jaffle_shop.orders", vim.NIL),
    }, function()
      local entries = quickfix.populate_from_run_results(fixture)
      assert.are.equal(1, #entries)

      local list = vim.fn.getqflist()
      assert.are.equal(1, #list)
      assert.are.equal("Binder Error", list[1].text)
      assert.are.equal("E", list[1].type)
      assert.are.equal(1, list[1].lnum)
      assert.is_true(list[1].bufnr > 0)
      assert.are.equal(
        fixture .. "/models/marts/customers.sql",
        vim.api.nvim_buf_get_name(list[1].bufnr)
      )
    end)

    vim.api.nvim_del_autocmd(autocmd)
    assert.is_true(fired)
  end)

  it("clears a stale list when the latest run has no failures", function()
    vim.fn.setqflist({ { filename = fixture .. "/models/marts/orders.sql", lnum = 1, text = "old" } }, "r")
    local entries = quickfix.populate_from_run_results(fixture)
    assert.are.same({}, entries)
    assert.are.equal(0, #vim.fn.getqflist())
  end)

  it("leaves the list alone when there are no run results at all", function()
    vim.fn.setqflist({ { filename = fixture .. "/models/marts/orders.sql", lnum = 1, text = "old" } }, "r")
    assert.is_nil(quickfix.populate_from_run_results(repo_root .. "/tests"))
    assert.are.equal(1, #vim.fn.getqflist())
  end)
end)
