-- Specs for the pure ASCII layered-DAG renderer. flowchart.lua has zero "vim."
-- references, so these run under bare lua/luajit with no editor present.

local flowchart = require("dbt-power-user.flowchart")

local function node(id, label, detail)
  return { id = id, label = label, detail = detail }
end

local function edge(from, to)
  return { from = from, to = to }
end

-- A box-drawing character or a run of "-" is present somewhere on this line.
local function has_char(line, ch)
  return line:find(ch, 1, true) ~= nil
end

describe("flowchart.build", function()
  it("returns nil for an empty node list", function()
    assert.is_nil(flowchart.build({}, {}))
  end)

  it("places a single node with no edges on its own line", function()
    local result = flowchart.build({ node("a", "a") }, {})
    assert.are.equal(1, #result.lines)
    assert.is_true(has_char(result.lines[1], "a"))
    assert.are.equal(1, result.line_of.a)
  end)

  it("lays out a simple three-link chain top to bottom, one hop per band", function()
    -- a feeds b feeds c: a must render above b, b above c, with a connector line
    -- between each consecutive pair.
    local result = flowchart.build(
      { node("a", "a"), node("b", "b"), node("c", "c") },
      { edge("a", "b"), edge("b", "c") }
    )
    assert.is_true(result.line_of.a < result.line_of.b)
    assert.is_true(result.line_of.b < result.line_of.c)
    -- a and c are never adjacent lines (there's a real connector band between each)
    assert.are.equal(2, result.line_of.b - result.line_of.a)
    assert.are.equal(2, result.line_of.c - result.line_of.b)
  end)

  it("merges a fan-in (two parents, one child) with a horizontal bar", function()
    local result = flowchart.build(
      { node("p1", "p1"), node("p2", "p2"), node("child", "child") },
      { edge("p1", "child"), edge("p2", "child") }
    )
    assert.are.equal(0, result.layer_of.p1)
    assert.are.equal(0, result.layer_of.p2)
    assert.are.equal(1, result.layer_of.child)
    local connector = result.lines[result.line_of.p1 + 1]
    assert.is_true(has_char(connector, "─")) -- the bar spans between the two parents
    -- the merge needs at least one upward and one downward junction character
    assert.is_true(connector:find("[┴┬┼├┤└┘]") ~= nil)
  end)

  it("splits a fan-out (one parent, two children in the same layer)", function()
    local result = flowchart.build(
      { node("parent", "parent"), node("c1", "c1"), node("c2", "c2") },
      { edge("parent", "c1"), edge("parent", "c2") }
    )
    assert.are.equal(0, result.layer_of.parent)
    assert.are.equal(1, result.layer_of.c1)
    assert.are.equal(1, result.layer_of.c2)
    local connector = result.lines[result.line_of.parent + 1]
    assert.is_true(has_char(connector, "─"))
  end)

  it("routes a skip edge (spanning more than one layer) as a plain pass-through", function()
    -- a feeds b feeds c, AND a feeds c directly (a shortcut two layers down).
    local result = flowchart.build(
      { node("a", "a"), node("b", "b"), node("c", "c") },
      { edge("a", "b"), edge("b", "c"), edge("a", "c") }
    )
    -- c's layer must be determined by the LONGEST path to it (via b), not the
    -- direct one-hop edge, or the direct edge would point backward/sideways.
    assert.are.equal(0, result.layer_of.a)
    assert.are.equal(1, result.layer_of.b)
    assert.are.equal(2, result.layer_of.c)
    -- the a->c edge must render as SOMETHING in the first connector band (a pass
    -- through column), not be silently dropped.
    local first_band = result.lines[result.line_of.a + 1]
    assert.is_true(#first_band:gsub(" ", "") > 0)
  end)

  it("does not drop a node whose label is wider than its single, narrow parent", function()
    -- centering a wide child under a narrow parent's center used to compute a
    -- negative left edge; anything written at a negative column silently vanished
    -- instead of erroring, which is exactly why this needs an explicit assertion.
    local result = flowchart.build(
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
    local result = flowchart.build(nodes, edges)
    local text = table.concat(result.lines, "\n")

    for _, n in ipairs(nodes) do
      assert.is_true(text:find(n.label, 1, true) ~= nil, n.label .. " missing from render")
      assert.is_not_nil(result.line_of[n.id], n.id .. " has no line number")
    end

    -- layering must strictly increase along every real edge (source above target)
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

  it("gives every sibling on a shared line its own non-overlapping box", function()
    -- layer 0 here has 5 siblings, all on the same label line -- exactly the shape
    -- that broke <CR> navigation before `boxes` existed: a naive line->file lookup
    -- can only remember ONE of the five.
    local nodes, edges = {}, {}
    for _, name in ipairs({ "raw_a", "raw_b", "raw_c", "raw_d", "raw_e" }) do
      nodes[#nodes + 1] = node(name, name, "source")
      edges[#edges + 1] = edge(name, "child")
    end
    nodes[#nodes + 1] = node("child", "child", "model")
    local result = flowchart.build(nodes, edges)

    local siblings = {}
    for _, n in ipairs(nodes) do
      if n.id ~= "child" then
        siblings[#siblings + 1] = n.id
      end
    end
    assert.are.equal(5, #siblings)

    local boxes_by_id = {}
    for _, box in ipairs(result.boxes) do
      boxes_by_id[box.id] = box
    end

    for _, id in ipairs(siblings) do
      assert.is_not_nil(boxes_by_id[id], id .. " has no box")
    end

    -- every pair of siblings on the same line must have non-overlapping column
    -- ranges, or a cursor sitting on one node's label could resolve to another's.
    for i = 1, #siblings do
      for j = i + 1, #siblings do
        local a, b = boxes_by_id[siblings[i]], boxes_by_id[siblings[j]]
        if a.line == b.line then
          local overlap = a.col_start <= b.col_end and b.col_start <= a.col_end
          assert.is_false(overlap, siblings[i] .. " and " .. siblings[j] .. " boxes overlap on line " .. a.line)
        end
      end
    end
  end)
end)
