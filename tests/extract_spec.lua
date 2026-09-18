-- Specs for the pure ref()/source() extractor.

local extract = require("dbt-power-user.extract")

local function span(text, item)
  return text:sub(item.start_byte, item.end_byte)
end

describe("extract purity", function()
  it("contains no editor API references", function()
    local candidates = vim.api.nvim_get_runtime_file("lua/dbt-power-user/extract.lua", false)
    local source = debug.getinfo(1, "S").source:gsub("^@", "")
    candidates[#candidates + 1] = source:gsub("tests/extract_spec%.lua$", "lua/dbt-power-user/extract.lua")

    local src
    for _, path in ipairs(candidates) do
      local fh = io.open(path, "r")
      if fh then
        src = fh:read("*a")
        fh:close()
        break
      end
    end

    assert.is_not_nil(src, "could not locate extract.lua on disk")
    assert.is_nil(src:find("vim%."), "extract.lua must not reference the editor API")
  end)
end)

describe("extract.find_refs", function()
  it("finds a simple single-quoted ref", function()
    local text = "select * from {{ ref('customers') }}"
    local refs = extract.find_refs(text)

    assert.equals(1, #refs)
    assert.equals("customers", refs[1].name)
    assert.is_nil(refs[1].pkg)
    assert.equals("{{ ref('customers')", span(text, refs[1]))
  end)

  it("finds a double-quoted ref", function()
    local refs = extract.find_refs('select * from {{ ref("stg_orders") }}')

    assert.equals(1, #refs)
    assert.equals("stg_orders", refs[1].name)
    assert.is_nil(refs[1].pkg)
  end)

  it("finds a package-qualified two-arg ref", function()
    local refs = extract.find_refs("select * from {{ ref('my_pkg','model_a') }}")

    assert.equals(1, #refs)
    assert.equals("my_pkg", refs[1].pkg)
    assert.equals("model_a", refs[1].name)
  end)

  it("finds a ref spanning multiple lines", function()
    local text = "select * from {{\n  ref('multi_line')\n}}"
    local refs = extract.find_refs(text)

    assert.equals(1, #refs)
    assert.equals("multi_line", refs[1].name)
  end)

  it("finds a ref using jinja whitespace control", function()
    local refs = extract.find_refs("select * from {{- ref('x') -}}")

    assert.equals(1, #refs)
    assert.equals("x", refs[1].name)
  end)

  it("finds two refs on one line", function()
    local text = "select 1 from {{ ref('one') }} join {{ ref('two') }} on true"
    local refs = extract.find_refs(text)

    assert.equals(2, #refs)
    assert.equals("one", refs[1].name)
    assert.equals("two", refs[2].name)
    assert.is_true(refs[1].end_byte < refs[2].start_byte)
  end)

  it("tolerates extra internal spaces", function()
    local refs = extract.find_refs("select * from {{ ref ( 'x' ) }}")

    assert.equals(1, #refs)
    assert.equals("x", refs[1].name)
  end)

  it("ignores a ref mentioned in a plain SQL comment with no braces", function()
    assert.equals(0, #extract.find_refs("-- ref('not_real')"))
    assert.equals(0, #extract.find_refs("select 1 as x -- ref('not_real')\nfrom t"))
  end)

  it("returns an empty list for text with no refs and for non-strings", function()
    assert.equals(0, #extract.find_refs("select * from customers"))
    assert.equals(0, #extract.find_refs(nil))
  end)

  it("does not match a macro whose name merely ends in ref", function()
    assert.equals(0, #extract.find_refs("{{ my_ref('customers') }}"))
  end)
end)

describe("extract.find_sources", function()
  it("finds a source with two args", function()
    local text = "select * from {{ source('raw','jaffle_shop_customers') }}"
    local sources = extract.find_sources(text)

    assert.equals(1, #sources)
    assert.equals("raw", sources[1].source_name)
    assert.equals("jaffle_shop_customers", sources[1].table_name)
    assert.equals("{{ source('raw','jaffle_shop_customers')", span(text, sources[1]))
  end)

  it("finds double-quoted, spaced and whitespace-controlled sources", function()
    local sources = extract.find_sources('{{- source ( "ecom" , "raw_items" ) -}}')

    assert.equals(1, #sources)
    assert.equals("ecom", sources[1].source_name)
    assert.equals("raw_items", sources[1].table_name)
  end)

  it("ignores a source mentioned in a plain SQL comment with no braces", function()
    assert.equals(0, #extract.find_sources("-- source('raw','not_real')"))
  end)

  it("does not confuse refs for sources", function()
    assert.equals(0, #extract.find_sources("{{ ref('customers') }}"))
    assert.equals(0, #extract.find_refs("{{ source('raw','orders') }}"))
  end)
end)

describe("extract.call_under_cursor", function()
  local text = "select *\nfrom {{ ref('customers') }}\njoin {{ source('raw','orders') }} using (id)"

  it("resolves a ref when the offset is inside its span", function()
    local call = extract.call_under_cursor(text, text:find("customers"))

    assert.is_not_nil(call)
    assert.equals("ref", call.kind)
    assert.equals("customers", call.name)
    assert.is_nil(call.pkg)
  end)

  it("resolves a source when the offset is inside its span", function()
    local call = extract.call_under_cursor(text, text:find("orders"))

    assert.is_not_nil(call)
    assert.equals("source", call.kind)
    assert.equals("raw", call.source_name)
    assert.equals("orders", call.table_name)
  end)

  it("resolves a two-arg ref and keeps the package", function()
    local qualified = "select * from {{ ref('my_pkg','model_a') }}"
    local call = extract.call_under_cursor(qualified, qualified:find("model_a"))

    assert.equals("ref", call.kind)
    assert.equals("my_pkg", call.pkg)
    assert.equals("model_a", call.name)
  end)

  it("returns nil when the offset sits outside every call", function()
    assert.is_nil(extract.call_under_cursor(text, 3))
    assert.is_nil(extract.call_under_cursor(text, #text))
    assert.is_nil(extract.call_under_cursor(text, nil))
  end)
end)

describe("extract.completion_context", function()
  it("detects the ref name position", function()
    assert.equals("ref_name", extract.completion_context("select * from {{ ref('"))
    assert.equals("ref_name", extract.completion_context("select * from {{ ref('cust"))
    assert.equals("ref_name", extract.completion_context('select * from {{ ref("stg_'))
    assert.equals("ref_name", extract.completion_context("select * from {{ ref("))
  end)

  it("detects the ref second-argument position", function()
    assert.equals("ref_pkg_name", extract.completion_context("select * from {{ ref('my_pkg', '"))
    assert.equals("ref_pkg_name", extract.completion_context("select * from {{ ref('my_pkg','mod"))
  end)

  it("detects the source name position", function()
    assert.equals("source_name", extract.completion_context("select * from {{ source('"))
    assert.equals("source_name", extract.completion_context("select * from {{ source('ra"))
  end)

  it("detects the source table position", function()
    assert.equals("source_table", extract.completion_context("select * from {{ source('raw', '"))
    assert.equals("source_table", extract.completion_context("select * from {{ source('raw','jaffle"))
  end)

  it("returns nil with no ref or source in sight", function()
    assert.is_nil(extract.completion_context("select * from "))
    assert.is_nil(extract.completion_context("select * fro"))
    assert.is_nil(extract.completion_context("select * from refunds"))
    assert.is_nil(extract.completion_context("select * from {{ ref('customers') }}"))
    assert.is_nil(extract.completion_context(nil))
  end)
end)
