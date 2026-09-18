-- Specs for the pure "%" selector expansion.

local selector = require("dbt-power-user.selector")

describe("selector.expand", function()
  it("expands a trailing downstream operator", function()
    assert.equals("customers+", selector.expand("%+", "customers"))
  end)

  it("expands an upstream operator", function()
    assert.equals("+customers", selector.expand("+%", "customers"))
  end)

  it("expands both directions at once", function()
    assert.equals("+customers+", selector.expand("+%+", "customers"))
  end)

  it("expands a bare placeholder", function()
    assert.equals("customers", selector.expand("%", "customers"))
  end)

  it("expands inside a comma-separated selector list", function()
    assert.equals("customers,@other", selector.expand("%,@other", "customers"))
  end)

  it("keeps a trailing comma", function()
    assert.equals("customers,", selector.expand("%,", "customers"))
  end)

  it("expands every placeholder in the string", function()
    assert.equals("+orders,orders+", selector.expand("+%,%+", "orders"))
  end)

  it("handles graph depth and state operators around the placeholder", function()
    assert.equals("2+stg_orders+3", selector.expand("2+%+3", "stg_orders"))
    assert.equals("stg_orders+,state:modified", selector.expand("%+,state:modified", "stg_orders"))
  end)

  it("leaves a selector without a placeholder untouched", function()
    assert.equals("tag:nightly+", selector.expand("tag:nightly+", "customers"))
    assert.equals("", selector.expand("", "customers"))
  end)

  it("does not treat the model name as a pattern replacement", function()
    -- A gsub-based implementation would mangle "%1"-style sequences in the replacement.
    assert.equals("odd%1name+", selector.expand("%+", "odd%1name"))
  end)

  it("returns the selector unchanged when there is no model name", function()
    assert.equals("%+", selector.expand("%+", nil))
    assert.equals("%+", selector.expand("%+", ""))
  end)

  it("returns nil for a non-string selector", function()
    assert.is_nil(selector.expand(nil, "customers"))
    assert.is_nil(selector.expand(42, "customers"))
  end)
end)
