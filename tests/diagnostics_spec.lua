local diagnostics = require("dbt-power-user.diagnostics")
local manifest = require("dbt-power-user.manifest")

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local fixture = repo_root .. "/tests/fixtures/jaffle-shop"

-- Ground truth read straight off tests/fixtures/jaffle-shop/target/*.json:
-- 13 models, all 13 present in the catalog, 4 without a patch_path, 61 catalog
-- columns with no matching manifest column entry, and none documented that the
-- warehouse does not have.
local MODELS_WITHOUT_DOCS = {
  "model.jaffle_shop.locations",
  "model.jaffle_shop.metricflow_time_spine",
  "model.jaffle_shop.products",
  "model.jaffle_shop.supplies",
}
local UNDOCUMENTED_COLUMNS = 61

local function messages_matching(list, pattern)
  local found = {}
  for _, entry in ipairs(list) do
    if entry.message:match(pattern) then
      found[#found + 1] = entry
    end
  end
  return found
end

describe("diagnostics.check", function()
  it("returns a flat list where every entry is fully populated", function()
    local list = diagnostics.check(fixture)
    assert.is_table(list)
    assert.is_true(#list > 0)
    for _, entry in ipairs(list) do
      assert.is_string(entry.unique_id)
      assert.is_string(entry.name)
      assert.is_string(entry.message)
      assert.are.equal(vim.diagnostic.severity.HINT, entry.severity)
      assert.is_true(#entry.unique_id > 0)
      assert.is_true(#entry.name > 0)
      assert.is_true(#entry.message > 0)
    end
  end)

  it("only ever reports real model nodes", function()
    local graph = manifest.graph(fixture)
    for _, entry in ipairs(diagnostics.check(fixture)) do
      local node = graph.nodes[entry.unique_id]
      assert.is_not_nil(node)
      assert.are.equal("model", node.resource_type)
      assert.are.equal(node.name, entry.name)
    end
  end)

  it("flags exactly the four jaffle-shop models with no patch_path", function()
    local flagged = messages_matching(diagnostics.check(fixture), "^Documentation missing for model: ")
    local ids = {}
    for _, entry in ipairs(flagged) do
      ids[#ids + 1] = entry.unique_id
    end
    table.sort(ids)
    assert.are.same(MODELS_WITHOUT_DOCS, ids)
  end)

  it("agrees with the manifest about which models lack a patch_path", function()
    local data = manifest.load(fixture)
    local expected = {}
    for unique_id, node in pairs(data.nodes) do
      if node.resource_type == "model" and type(node.patch_path) ~= "string" then
        expected[#expected + 1] = unique_id
      end
    end
    table.sort(expected)
    assert.are.same(MODELS_WITHOUT_DOCS, expected)
  end)

  it("uses the verbatim VSCode message text", function()
    local flagged = messages_matching(diagnostics.check(fixture), "^Documentation missing for model: locations$")
    assert.are.equal(1, #flagged)
    assert.are.equal("Documentation missing for model: locations", flagged[1].message)
  end)

  it("reports no model as missing from the database, since all 13 are built", function()
    assert.are.equal(0, #messages_matching(diagnostics.check(fixture), "does not exist in the database"))
  end)

  it("counts the real undocumented columns", function()
    local flagged = messages_matching(diagnostics.check(fixture), "^Column .* is undocumented in model: ")
    assert.are.equal(UNDOCUMENTED_COLUMNS, #flagged)
  end)

  it("names a known undocumented column and its model", function()
    local flagged = messages_matching(
      diagnostics.check(fixture),
      "^Column location_name is undocumented in model: locations$"
    )
    assert.are.equal(1, #flagged)
    assert.are.equal("model.jaffle_shop.locations", flagged[1].unique_id)
    assert.are.equal("location_name", flagged[1].column)
  end)

  it("reports no documented column as absent from the database", function()
    assert.are.equal(0, #messages_matching(diagnostics.check(fixture), "is not found in the database%.$"))
  end)

  it("reports 5 diagnostics for locations and 11 for orders", function()
    local by_model = {}
    for _, entry in ipairs(diagnostics.check(fixture)) do
      by_model[entry.unique_id] = (by_model[entry.unique_id] or 0) + 1
    end
    assert.are.equal(5, by_model["model.jaffle_shop.locations"])
    assert.are.equal(11, by_model["model.jaffle_shop.orders"])
    assert.is_nil(by_model["model.jaffle_shop.customers"])
  end)

  it("totals the four categories", function()
    assert.are.equal(#MODELS_WITHOUT_DOCS + UNDOCUMENTED_COLUMNS, #diagnostics.check(fixture))
  end)

  it("is deterministically ordered across calls", function()
    local first, second = diagnostics.check(fixture), diagnostics.check(fixture)
    assert.are.equal(#first, #second)
    for index, entry in ipairs(first) do
      assert.are.equal(entry.message, second[index].message)
      assert.are.equal(entry.unique_id, second[index].unique_id)
    end
  end)

  it("returns an empty list when there is no manifest", function()
    assert.are.same({}, diagnostics.check(repo_root .. "/tests"))
  end)

  it("returns an empty list for a nil or empty root", function()
    assert.are.same({}, diagnostics.check(nil))
    assert.are.same({}, diagnostics.check(""))
  end)
end)

describe("diagnostics.refresh_buffer", function()
  -- Sibling spec files open the same fixture models, so without these a leftover swap
  -- file turns bufload into an interactive E325 prompt and the run fails at random.
  before_each(function()
    vim.opt.swapfile = false
    vim.opt.shortmess:append("A")
  end)

  local function open(path)
    local bufnr = vim.fn.bufadd(path)
    vim.bo[bufnr].swapfile = false
    vim.fn.bufload(bufnr)
    return bufnr
  end

  it("sets only the current buffer's model diagnostics", function()
    local bufnr = open(fixture .. "/models/marts/locations.sql")
    diagnostics.refresh_buffer(bufnr, fixture)

    local set = vim.diagnostic.get(bufnr, { namespace = diagnostics.ns })
    assert.are.equal(5, #set)
    for _, entry in ipairs(set) do
      assert.are.equal(vim.diagnostic.severity.HINT, entry.severity)
      assert.are.equal("dbt", entry.source)
      assert.is_true(entry.lnum >= 0)
      assert.is_true(entry.message:match("locations") ~= nil)
    end
  end)

  it("anchors a column diagnostic to the line the column appears on", function()
    local bufnr = open(fixture .. "/models/marts/orders.sql")
    diagnostics.refresh_buffer(bufnr, fixture)

    local set = vim.diagnostic.get(bufnr, { namespace = diagnostics.ns })
    assert.are.equal(11, #set)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local anchored = 0
    for _, entry in ipairs(set) do
      local column = entry.message:match("^Column ([%w_]+) ")
      if column and lines[entry.lnum + 1] and lines[entry.lnum + 1]:find(column, 1, true) then
        anchored = anchored + 1
      end
    end
    assert.is_true(anchored > 0)
  end)

  it("clears diagnostics for a buffer that is not a dbt node", function()
    local bufnr = open(fixture .. "/README.md")
    diagnostics.refresh_buffer(bufnr, fixture)
    assert.are.equal(0, #vim.diagnostic.get(bufnr, { namespace = diagnostics.ns }))
  end)

  it("does not error on an invalid buffer", function()
    assert.has_no.errors(function()
      diagnostics.refresh_buffer(123456, fixture)
    end)
  end)
end)
