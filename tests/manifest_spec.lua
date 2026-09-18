local manifest = require("dbt-power-user.manifest")

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local fixture = repo_root .. "/tests/fixtures/jaffle-shop"

local function count(tbl)
  local n = 0
  for _ in pairs(tbl) do
    n = n + 1
  end
  return n
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

describe("manifest.load", function()
  it("loads the real jaffle-shop manifest", function()
    local data = manifest.load(fixture)
    assert.is_not_nil(data)
    assert.are.equal("jaffle_shop", data.metadata.project_name)
    assert.are.equal(40, count(data.nodes))
    assert.are.equal(6, count(data.sources))
  end)

  it("returns the identical table on a memoized second call", function()
    local first = manifest.load(fixture)
    local second = manifest.load(fixture)
    assert.are.equal(first, second)
  end)

  it("rebuilds after invalidate", function()
    local first = manifest.load(fixture)
    manifest.invalidate(fixture)
    local second = manifest.load(fixture)
    assert.are_not.equal(first, second)
    assert.are.equal(40, count(second.nodes))
  end)

  it("returns nil when the project has no target/manifest.json", function()
    assert.is_nil(manifest.load(repo_root .. "/tests"))
  end)

  it("returns nil for a nil or empty root", function()
    assert.is_nil(manifest.load(nil))
    assert.is_nil(manifest.load(""))
  end)
end)

describe("manifest.load_catalog", function()
  it("loads the real catalog with its 13 built models", function()
    local catalog = manifest.load_catalog(fixture)
    assert.is_not_nil(catalog)
    assert.are.equal(13, count(catalog.nodes))
    assert.are.equal(6, count(catalog.sources))
  end)

  it("exposes real column metadata for a built model", function()
    local catalog = manifest.load_catalog(fixture)
    local node = catalog.nodes["model.jaffle_shop.customers"]
    assert.is_not_nil(node)
    assert.is_not_nil(node.columns.customer_id)
    assert.are.equal("VARCHAR", node.columns.customer_id.type)
  end)

  it("treats an absent node as not-built-yet rather than an error", function()
    local catalog = manifest.load_catalog(fixture)
    assert.is_nil(catalog.nodes["test.jaffle_shop.not_null_customers_customer_id.5c9bf9911d"])
  end)

  it("returns nil when there is no catalog", function()
    assert.is_nil(manifest.load_catalog(repo_root .. "/tests"))
  end)
end)

describe("manifest.load_run_results", function()
  it("loads the real run_results", function()
    -- run_results.json reflects whatever dbt command was last run against the fixture
    -- (its node count and args.which change with every real invocation, including this
    -- plugin's own end-to-end checks), so assert its shape, not an exact entry count.
    local results = manifest.load_run_results(fixture)
    assert.is_not_nil(results)
    assert.is_table(results.results)
    assert.is_true(#results.results > 0)
    assert.is_not_nil(results.results[1].unique_id)
    assert.is_not_nil(results.results[1].status)
  end)

  it("returns nil when there are no run results", function()
    assert.is_nil(manifest.load_run_results(repo_root .. "/tests"))
  end)
end)

describe("manifest.graph", function()
  it("projects the 13 models and 6 sources and nothing else", function()
    local graph = manifest.graph(fixture)
    assert.are.equal(19, count(graph.nodes))

    local by_type = {}
    for _, node in pairs(graph.nodes) do
      by_type[node.resource_type] = (by_type[node.resource_type] or 0) + 1
    end
    assert.are.equal(13, by_type.model)
    assert.are.equal(6, by_type.source)
    assert.is_nil(by_type.test)
  end)

  it("gives customers exactly 2 parents, stg_customers and orders", function()
    local graph = manifest.graph(fixture)
    local parents = graph.parents["model.jaffle_shop.customers"]
    assert.are.equal(2, #parents)
    assert.is_true(contains(parents, "model.jaffle_shop.stg_customers"))
    assert.is_true(contains(parents, "model.jaffle_shop.orders"))
  end)

  it("filters test nodes out of both endpoints of every edge", function()
    local graph = manifest.graph(fixture)
    for unique_id, parents in pairs(graph.parents) do
      assert.is_nil(unique_id:match("^test%."))
      for _, parent in ipairs(parents) do
        assert.is_nil(parent:match("^test%."))
        assert.is_not_nil(graph.nodes[parent])
      end
    end
    for unique_id, children in pairs(graph.children) do
      assert.is_nil(unique_id:match("^test%."))
      for _, child in ipairs(children) do
        assert.is_nil(child:match("^test%."))
        assert.is_not_nil(graph.nodes[child])
      end
    end
  end)

  it("leaves customers with no children even though child_map lists 5", function()
    -- child_map holds 4 tests and a semantic_model for customers, zero real models.
    local raw = manifest.load(fixture)
    assert.are.equal(5, #raw.child_map["model.jaffle_shop.customers"])
    assert.are.equal(0, #manifest.graph(fixture).children["model.jaffle_shop.customers"])
  end)

  it("drops semantic_model and unit_test endpoints too", function()
    local graph = manifest.graph(fixture)
    local children = graph.children["model.jaffle_shop.orders"]
    assert.are.equal(1, #children)
    assert.are.equal("model.jaffle_shop.customers", children[1])
  end)

  it("never returns nil parent or child lists", function()
    local graph = manifest.graph(fixture)
    for unique_id in pairs(graph.nodes) do
      assert.is_table(graph.parents[unique_id])
      assert.is_table(graph.children[unique_id])
    end
  end)

  it("walks the known 5-level source-to-mart chain", function()
    local graph = manifest.graph(fixture)
    assert.are.same({ "source.jaffle_shop.ecom.raw_items" }, graph.parents["model.jaffle_shop.stg_order_items"])
    assert.are.same({ "model.jaffle_shop.order_items" }, graph.children["model.jaffle_shop.stg_order_items"])
    assert.is_true(contains(graph.parents["model.jaffle_shop.order_items"], "model.jaffle_shop.stg_order_items"))
    assert.are.same({ "model.jaffle_shop.orders" }, graph.children["model.jaffle_shop.order_items"])
    assert.is_true(contains(graph.parents["model.jaffle_shop.orders"], "model.jaffle_shop.order_items"))
    assert.are.same({ "model.jaffle_shop.customers" }, graph.children["model.jaffle_shop.orders"])
  end)

  it("treats metricflow_time_spine as a root node", function()
    local graph = manifest.graph(fixture)
    assert.are.equal(0, #graph.parents["model.jaffle_shop.metricflow_time_spine"])
  end)

  it("gives sources no parents and real model children", function()
    local graph = manifest.graph(fixture)
    assert.are.equal(0, #graph.parents["source.jaffle_shop.ecom.raw_items"])
    assert.are.same({ "model.jaffle_shop.stg_order_items" }, graph.children["source.jaffle_shop.ecom.raw_items"])
  end)

  it("projects the fields the rest of the plugin reads", function()
    local node = manifest.graph(fixture).nodes["model.jaffle_shop.customers"]
    assert.are.equal("customers", node.name)
    assert.are.equal("model", node.resource_type)
    assert.are.equal("marts/customers.sql", node.path)
    assert.are.equal("models/marts/customers.sql", node.original_file_path)
    assert.are.equal("jaffle_shop", node.package_name)
    assert.are.equal("jaffle_shop", node.database)
    assert.are.equal("main", node.schema)
    assert.are.equal("table", node.materialized)
  end)

  it("reads the real materialized value rather than the fallback", function()
    local nodes = manifest.graph(fixture).nodes
    assert.are.equal("view", nodes["model.jaffle_shop.stg_customers"].materialized)
    assert.are.equal("table", nodes["model.jaffle_shop.orders"].materialized)
  end)

  it("falls back to view when config.materialized is genuinely absent", function()
    -- Sources carry no materialized key at all, so they exercise the fallback.
    local raw = manifest.load(fixture)
    assert.is_nil(raw.sources["source.jaffle_shop.ecom.raw_items"].config.materialized)
    assert.are.equal("view", manifest.graph(fixture).nodes["source.jaffle_shop.ecom.raw_items"].materialized)
  end)

  it("returns the identical graph on a memoized second call", function()
    assert.are.equal(manifest.graph(fixture), manifest.graph(fixture))
  end)

  it("returns an empty but usable graph when there is no manifest", function()
    local graph = manifest.graph(repo_root .. "/tests")
    assert.are.equal(0, count(graph.nodes))
    assert.is_table(graph.parents)
    assert.is_table(graph.children)
  end)
end)

describe("manifest.find_node_by_name", function()
  it("finds a model by bare name", function()
    assert.are.equal("model.jaffle_shop.customers", manifest.find_node_by_name(fixture, "customers"))
  end)

  it("honours a model resource_type filter", function()
    assert.are.equal(
      "model.jaffle_shop.stg_orders",
      manifest.find_node_by_name(fixture, "stg_orders", "model")
    )
    assert.is_nil(manifest.find_node_by_name(fixture, "stg_orders", "source"))
  end)

  it("finds a source by table name and by dotted name", function()
    assert.are.equal(
      "source.jaffle_shop.ecom.raw_items",
      manifest.find_node_by_name(fixture, "raw_items", "source")
    )
    assert.are.equal(
      "source.jaffle_shop.ecom.raw_items",
      manifest.find_node_by_name(fixture, "ecom.raw_items", "source")
    )
  end)

  it("never resolves a test node", function()
    assert.is_nil(manifest.find_node_by_name(fixture, "not_null_customers_customer_id"))
  end)

  it("returns nil for an unknown name or empty input", function()
    assert.is_nil(manifest.find_node_by_name(fixture, "no_such_model"))
    assert.is_nil(manifest.find_node_by_name(fixture, ""))
    assert.is_nil(manifest.find_node_by_name(fixture, nil))
  end)
end)

describe("manifest.find_node_by_path", function()
  it("resolves an absolute model path", function()
    assert.are.equal(
      "model.jaffle_shop.customers",
      manifest.find_node_by_path(fixture, fixture .. "/models/marts/customers.sql")
    )
  end)

  it("resolves a project-relative original_file_path", function()
    assert.are.equal(
      "model.jaffle_shop.stg_orders",
      manifest.find_node_by_path(fixture, "models/staging/stg_orders.sql")
    )
  end)

  it("resolves a models-relative path via the node's own path field", function()
    assert.are.equal(
      "model.jaffle_shop.orders",
      manifest.find_node_by_path(fixture, "marts/orders.sql")
    )
  end)

  it("resolves a sources yml deterministically", function()
    local first = manifest.find_node_by_path(fixture, fixture .. "/models/staging/__sources.yml")
    assert.are.equal("source.jaffle_shop.ecom.raw_customers", first)
    assert.are.equal(first, manifest.find_node_by_path(fixture, "models/staging/__sources.yml"))
  end)

  it("returns nil for a path outside the project", function()
    assert.is_nil(manifest.find_node_by_path(fixture, "/tmp/elsewhere.sql"))
  end)

  it("returns nil for an unknown file inside the project", function()
    assert.is_nil(manifest.find_node_by_path(fixture, "models/marts/not_a_model.sql"))
  end)

  it("returns nil for empty input", function()
    assert.is_nil(manifest.find_node_by_path(fixture, ""))
    assert.is_nil(manifest.find_node_by_path("", "models/marts/orders.sql"))
  end)
end)

describe("manifest.macro_lookup", function()
  it("resolves a bare current-project macro", function()
    local macro = manifest.macro_lookup(fixture, "cents_to_dollars")
    assert.is_not_nil(macro)
    assert.are.equal("macro.jaffle_shop.cents_to_dollars", macro.unique_id)
    assert.are.equal("macros/cents_to_dollars.sql", macro.original_file_path)
  end)

  it("resolves a package-qualified installed-package macro", function()
    local macro = manifest.macro_lookup(fixture, "dbt_utils.star")
    assert.is_not_nil(macro)
    assert.are.equal("macro.dbt_utils.star", macro.unique_id)
  end)

  it("resolves a self-prefixed call to the current project's macro", function()
    local macro = manifest.macro_lookup(fixture, "jaffle_shop.cents_to_dollars")
    assert.are.equal("macro.jaffle_shop.cents_to_dollars", macro.unique_id)
  end)

  it("prefers the root project when a name exists in several packages", function()
    -- generate_schema_name is defined by both jaffle_shop and dbt.
    local macro = manifest.macro_lookup(fixture, "generate_schema_name")
    assert.are.equal("macro.jaffle_shop.generate_schema_name", macro.unique_id)
  end)

  it("still honours an explicit package for a shadowed name", function()
    local macro = manifest.macro_lookup(fixture, "dbt.generate_schema_name")
    assert.are.equal("macro.dbt.generate_schema_name", macro.unique_id)
  end)

  it("falls back to the bare name when the named package has no such macro", function()
    local macro = manifest.macro_lookup(fixture, "nope.cents_to_dollars")
    assert.are.equal("macro.jaffle_shop.cents_to_dollars", macro.unique_id)
  end)

  it("returns nil for an unknown macro or empty input", function()
    assert.is_nil(manifest.macro_lookup(fixture, "no_such_macro"))
    assert.is_nil(manifest.macro_lookup(fixture, ""))
    assert.is_nil(manifest.macro_lookup(fixture, nil))
    assert.is_nil(manifest.macro_lookup(repo_root .. "/tests", "cents_to_dollars"))
  end)
end)

describe("manifest.sources", function()
  it("maps source_name and table_name to unique_ids", function()
    local sources = manifest.sources(fixture)
    assert.are.equal(1, count(sources))
    assert.are.equal(6, count(sources.ecom))
    assert.are.equal("source.jaffle_shop.ecom.raw_items", sources.ecom.raw_items)
    assert.are.equal("source.jaffle_shop.ecom.raw_customers", sources.ecom.raw_customers)
  end)

  it("returns the identical table on a memoized second call", function()
    assert.are.equal(manifest.sources(fixture), manifest.sources(fixture))
  end)

  it("returns an empty table when there is no manifest", function()
    assert.are.equal(0, count(manifest.sources(repo_root .. "/tests")))
  end)
end)

describe("manifest.watch", function()
  it("returns a single fs_event handle per root and reuses it", function()
    local first = manifest.watch(fixture, function() end)
    assert.is_not_nil(first)
    assert.are.equal(first, manifest.watch(fixture, function() end))
    first:stop()
  end)

  it("returns nil for a nil or empty root", function()
    assert.is_nil(manifest.watch(nil, function() end))
    assert.is_nil(manifest.watch("", function() end))
  end)
end)
