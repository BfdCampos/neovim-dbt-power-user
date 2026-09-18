local lineage = require("dbt-power-user.lineage")

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local fixture = repo_root .. "/tests/fixtures/jaffle-shop"

local CUSTOMERS = "model.jaffle_shop.customers"
local ORDERS = "model.jaffle_shop.orders"
local ORDER_ITEMS = "model.jaffle_shop.order_items"
local STG_CUSTOMERS = "model.jaffle_shop.stg_customers"
local STG_ORDERS = "model.jaffle_shop.stg_orders"
local STG_ORDER_ITEMS = "model.jaffle_shop.stg_order_items"
local RAW_ITEMS = "source.jaffle_shop.ecom.raw_items"
local RAW_CUSTOMERS = "source.jaffle_shop.ecom.raw_customers"
local TIME_SPINE = "model.jaffle_shop.metricflow_time_spine"

-- unique_id -> depth, plus how many times each id shows up anywhere in the tree
local function index(tree)
  local depths, counts = {}, {}
  local function visit(node, depth)
    counts[node.unique_id] = (counts[node.unique_id] or 0) + 1
    if not depths[node.unique_id] then
      depths[node.unique_id] = depth
    end
    for _, child in ipairs(node.children) do
      visit(child, depth + 1)
    end
  end
  visit(tree, 0)
  return depths, counts
end

local function child_names(node)
  local names = {}
  for _, child in ipairs(node.children) do
    names[#names + 1] = child.name
  end
  table.sort(names)
  return names
end

local function only_child(node)
  assert.are.equal(1, #node.children)
  return node.children[1]
end

describe("lineage.ancestors", function()
  it("returns the requested node as the root of the tree", function()
    local tree = lineage.ancestors(fixture, CUSTOMERS)
    assert.is_not_nil(tree)
    assert.are.equal(CUSTOMERS, tree.unique_id)
    assert.are.equal("customers", tree.name)
    assert.are.equal("model", tree.resource_type)
    assert.is_table(tree.children)
  end)

  it("gives customers its two real parents, stg_customers and orders", function()
    local tree = lineage.ancestors(fixture, CUSTOMERS)
    assert.are.equal(2, #tree.children)
    assert.are.same({ "orders", "stg_customers" }, child_names(tree))
  end)

  it("walks the 4-model chain up from customers to its raw source", function()
    local depths = index(lineage.ancestors(fixture, CUSTOMERS))
    assert.are.equal(0, depths[CUSTOMERS])
    assert.are.equal(1, depths[ORDERS])
    assert.are.equal(2, depths[ORDER_ITEMS])
    assert.are.equal(3, depths[STG_ORDER_ITEMS])
    assert.are.equal(4, depths[RAW_ITEMS])
  end)

  it("reaches raw_customers via the other branch", function()
    local depths = index(lineage.ancestors(fixture, CUSTOMERS))
    assert.are.equal(1, depths[STG_CUSTOMERS])
    assert.are.equal(2, depths[RAW_CUSTOMERS])
  end)

  it("stops at max_depth", function()
    local depths = index(lineage.ancestors(fixture, CUSTOMERS, 1))
    assert.are.equal(1, depths[ORDERS])
    assert.are.equal(1, depths[STG_CUSTOMERS])
    assert.is_nil(depths[ORDER_ITEMS])
    assert.is_nil(depths[RAW_CUSTOMERS])
  end)

  it("truncates the long branch before its source at max_depth 3", function()
    local depths = index(lineage.ancestors(fixture, CUSTOMERS, 3))
    assert.are.equal(3, depths[STG_ORDER_ITEMS])
    assert.is_nil(depths[RAW_ITEMS])
  end)

  it("returns the bare node at max_depth 0", function()
    local tree = lineage.ancestors(fixture, CUSTOMERS, 0)
    assert.are.equal(CUSTOMERS, tree.unique_id)
    assert.are.equal(0, #tree.children)
  end)

  it("visits a diamond parent exactly once, at its shallowest depth", function()
    -- stg_orders feeds both orders (depth 1) and order_items (depth 2).
    local depths, counts = index(lineage.ancestors(fixture, CUSTOMERS))
    assert.are.equal(1, counts[STG_ORDERS])
    assert.are.equal(2, depths[STG_ORDERS])
  end)

  it("never repeats any node in the tree", function()
    local _, counts = index(lineage.ancestors(fixture, CUSTOMERS))
    for unique_id, seen in pairs(counts) do
      assert.are.equal(1, seen, unique_id .. " appeared " .. seen .. " times")
    end
  end)

  it("gives a root model no ancestors", function()
    local tree = lineage.ancestors(fixture, TIME_SPINE)
    assert.are.equal(TIME_SPINE, tree.unique_id)
    assert.are.equal(0, #tree.children)
  end)

  it("gives a source no ancestors", function()
    local tree = lineage.ancestors(fixture, RAW_ITEMS)
    assert.are.equal("source", tree.resource_type)
    assert.are.equal(0, #tree.children)
  end)

  it("gives every node in the tree a children table", function()
    local function check(node)
      assert.is_table(node.children)
      assert.is_string(node.unique_id)
      assert.is_string(node.name)
      assert.is_string(node.resource_type)
      for _, child in ipairs(node.children) do
        check(child)
      end
    end
    check(lineage.ancestors(fixture, CUSTOMERS))
  end)

  it("returns nil for an unknown or filtered-out node", function()
    assert.is_nil(lineage.ancestors(fixture, "model.jaffle_shop.no_such_model"))
    assert.is_nil(lineage.ancestors(fixture, "test.jaffle_shop.not_null_customers_customer_id.5c9bf9911d"))
    assert.is_nil(lineage.ancestors(fixture, ""))
  end)

  it("returns nil when there is no manifest", function()
    assert.is_nil(lineage.ancestors(repo_root .. "/tests", CUSTOMERS))
  end)
end)

describe("lineage.descendants", function()
  it("walks raw_items down the 4-model chain to customers", function()
    local tree = lineage.descendants(fixture, RAW_ITEMS)
    assert.are.equal(RAW_ITEMS, tree.unique_id)

    local stg = only_child(tree)
    assert.are.equal(STG_ORDER_ITEMS, stg.unique_id)
    local items = only_child(stg)
    assert.are.equal(ORDER_ITEMS, items.unique_id)
    local orders = only_child(items)
    assert.are.equal(ORDERS, orders.unique_id)
    local customers = only_child(orders)
    assert.are.equal(CUSTOMERS, customers.unique_id)
    assert.are.equal(0, #customers.children)
  end)

  it("puts each model of that chain one hop further down", function()
    local depths = index(lineage.descendants(fixture, RAW_ITEMS))
    assert.are.equal(0, depths[RAW_ITEMS])
    assert.are.equal(1, depths[STG_ORDER_ITEMS])
    assert.are.equal(2, depths[ORDER_ITEMS])
    assert.are.equal(3, depths[ORDERS])
    assert.are.equal(4, depths[CUSTOMERS])
  end)

  it("stops the chain at max_depth", function()
    local depths = index(lineage.descendants(fixture, RAW_ITEMS, 2))
    assert.are.equal(2, depths[ORDER_ITEMS])
    assert.is_nil(depths[ORDERS])
    assert.is_nil(depths[CUSTOMERS])
  end)

  it("gives stg_orders both of its direct children", function()
    local tree = lineage.descendants(fixture, STG_ORDERS)
    assert.are.equal(2, #tree.children)
    assert.are.same({ "order_items", "orders" }, child_names(tree))
  end)

  it("visits a diamond child exactly once", function()
    -- orders is both a direct child of stg_orders and a child of order_items.
    local depths, counts = index(lineage.descendants(fixture, STG_ORDERS))
    assert.are.equal(1, counts[ORDERS])
    assert.are.equal(1, depths[ORDERS])
    assert.are.equal(2, depths[CUSTOMERS])
  end)

  it("gives a leaf mart no descendants", function()
    assert.are.equal(0, #lineage.descendants(fixture, CUSTOMERS).children)
  end)

  it("gives an isolated model no descendants", function()
    assert.are.equal(0, #lineage.descendants(fixture, TIME_SPINE).children)
  end)

  it("never crosses into a test node", function()
    local _, counts = index(lineage.descendants(fixture, RAW_ITEMS))
    for unique_id in pairs(counts) do
      assert.is_nil(unique_id:match("^test%."))
    end
  end)

  it("returns nil for an unknown node", function()
    assert.is_nil(lineage.descendants(fixture, "source.jaffle_shop.ecom.no_such_table"))
  end)
end)
