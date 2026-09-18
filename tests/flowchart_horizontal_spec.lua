-- Specs for flowchart.build's horizontal (left-to-right) orientation. Mirrors
-- flowchart_spec.lua's vertical cases with the axes swapped.

local flowchart = require("dbt-power-user.flowchart")

local function node(id, label, detail)
  return { id = id, label = label, detail = detail }
end
local function edge(from, to)
  return { from = from, to = to }
end
local function has_char(line, ch)
  return line:find(ch, 1, true) ~= nil
end
local function build_h(nodes, edges)
  return flowchart.build(nodes, edges, { direction = "horizontal" })
end

describe("flowchart.build (horizontal)", function()
  it("returns nil for an empty node list", function()
    assert.is_nil(build_h({}, {}))
  end)

  it("places a single node with no edges on its own line", function()
    local result = build_h({ node("a", "a") }, {})
    assert.are.equal(1, #result.lines)
    assert.is_true(has_char(result.lines[1], "a"))
    assert.are.equal(1, result.line_of.a)
  end)

  it("lays a three-link chain out left to right: same row, increasing column", function()
    local result = build_h(
      { node("a", "a"), node("b", "b"), node("c", "c") },
      { edge("a", "b"), edge("b", "c") }
    )
    -- all three land on the same row (a single chain has no siblings to stack)
    assert.are.equal(result.line_of.a, result.line_of.b)
    assert.are.equal(result.line_of.b, result.line_of.c)
    local line = result.lines[result.line_of.a]
    local a_col = line:find("a", 1, true)
    local b_col = line:find("b", 1, true)
    local c_col = line:find("c", 1, true)
    assert.is_true(a_col < b_col)
    assert.is_true(b_col < c_col)
  end)

  it("stacks a fan-in (two parents, one child) onto separate rows with a connector", function()
    local result = build_h(
      { node("p1", "p1"), node("p2", "p2"), node("child", "child") },
      { edge("p1", "child"), edge("p2", "child") }
    )
    assert.are.equal(0, result.layer_of.p1)
    assert.are.equal(0, result.layer_of.p2)
    assert.are.equal(1, result.layer_of.child)
    assert.are_not.equal(result.line_of.p1, result.line_of.p2)
    local text = table.concat(result.lines, "\n")
    assert.is_true(text:find("[│┴┬┼├┤└┘]") ~= nil)
  end)

  it("stacks a fan-out (one parent, two children) onto separate rows", function()
    local result = build_h(
      { node("parent", "parent"), node("c1", "c1"), node("c2", "c2") },
      { edge("parent", "c1"), edge("parent", "c2") }
    )
    assert.are.equal(1, result.layer_of.c1)
    assert.are.equal(1, result.layer_of.c2)
    assert.are_not.equal(result.line_of.c1, result.line_of.c2)
  end)

  it("routes a skip edge without dropping the shortcut", function()
    local result = build_h(
      { node("a", "a"), node("b", "b"), node("c", "c") },
      { edge("a", "b"), edge("b", "c"), edge("a", "c") }
    )
    assert.are.equal(0, result.layer_of.a)
    assert.are.equal(1, result.layer_of.b)
    assert.are.equal(2, result.layer_of.c)
  end)

  it("does not drop a node whose label is wider than its single, narrow parent", function()
    local result = build_h(
      { node("p", "p"), node("a_very_long_child_name", "a_very_long_child_name") },
      { edge("p", "a_very_long_child_name") }
    )
    local text = table.concat(result.lines, "\n")
    assert.is_true(has_char(text, "a_very_long_child_name"))
    assert.is_true(has_char(text, "p"))
  end)

  it("builds the real jaffle-shop customers upstream lineage without dropping any node", function()
    local nodes = {
      node("raw_items", "raw_items", "source"),
      node("raw_products", "raw_products", "source"),
      node("raw_supplies", "raw_supplies", "source"),
      node("raw_orders", "raw_orders", "source"),
      node("raw_customers", "raw_customers", "source"),
      node("stg_order_items", "stg_order_items", "model · view"),
      node("stg_products", "stg_products", "model · view"),
      node("stg_supplies", "stg_supplies", "model · view"),
      node("stg_orders", "stg_orders", "model · view"),
      node("stg_customers", "stg_customers", "model · view"),
      node("order_items", "order_items", "model · table"),
      node("orders", "orders", "model · table"),
      node("customers", "customers", "model · table"),
    }
    local edges = {
      edge("raw_items", "stg_order_items"),
      edge("raw_products", "stg_products"),
      edge("raw_supplies", "stg_supplies"),
      edge("raw_orders", "stg_orders"),
      edge("raw_customers", "stg_customers"),
      edge("stg_order_items", "order_items"),
      edge("stg_products", "order_items"),
      edge("stg_supplies", "order_items"),
      edge("stg_orders", "orders"),
      edge("order_items", "orders"),
      edge("stg_customers", "customers"),
      edge("orders", "customers"),
    }
    local result = build_h(nodes, edges)
    local text = table.concat(result.lines, "\n")

    for _, n in ipairs(nodes) do
      assert.is_true(text:find(n.label, 1, true) ~= nil, n.label .. " missing from render")
      assert.is_not_nil(result.line_of[n.id], n.id .. " has no line number")
    end

    for _, e in ipairs(edges) do
      assert.is_true(
        result.layer_of[e.to] > result.layer_of[e.from],
        e.from .. " -> " .. e.to .. " did not increase in layer"
      )
    end

    assert.are.equal(0, result.layer_of.raw_items)
    assert.are.equal(1, result.layer_of.stg_order_items)
    assert.are.equal(2, result.layer_of.order_items)
    assert.are.equal(3, result.layer_of.orders)
    assert.are.equal(4, result.layer_of.customers)
  end)

  it("gives every node on a shared line its own non-overlapping box", function()
    -- a straight-through chain lands multiple layers on the SAME row in horizontal
    -- mode -- exactly the shape that broke <CR> navigation before `boxes` existed.
    local result = build_h(
      { node("a", "a"), node("b", "b"), node("c", "c") },
      { edge("a", "b"), edge("b", "c") }
    )
    local boxes_by_id = {}
    for _, box in ipairs(result.boxes) do
      boxes_by_id[box.id] = box
    end
    assert.are.equal(boxes_by_id.a.line, boxes_by_id.b.line)
    assert.are.equal(boxes_by_id.b.line, boxes_by_id.c.line)

    local ids = { "a", "b", "c" }
    for i = 1, #ids do
      for j = i + 1, #ids do
        local x, y = boxes_by_id[ids[i]], boxes_by_id[ids[j]]
        local overlap = x.col_start <= y.col_end and y.col_start <= x.col_end
        assert.is_false(overlap, ids[i] .. " and " .. ids[j] .. " boxes overlap")
      end
    end
  end)
end)
