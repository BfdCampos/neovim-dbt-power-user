local project = require("dbt-power-user.project")

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local fixture = repo_root .. "/tests/fixtures/jaffle-shop"

describe("project.parse_dbt_project_yml", function()
  it("reads name, profile and target-path from the real jaffle-shop project", function()
    local parsed = project.parse_dbt_project_yml(fixture)
    assert.is_not_nil(parsed)
    assert.are.equal("jaffle_shop", parsed.name)
    assert.are.equal("default", parsed.profile)
    assert.are.equal("target", parsed.target_path)
  end)

  it("strips a trailing comment from the profile line", function()
    -- the fixture's line is: profile: default # Put your profile here
    local parsed = project.parse_dbt_project_yml(fixture)
    assert.is_nil(parsed.profile:match("#"))
  end)

  it("ignores indented keys such as dbt-cloud's project-id", function()
    local parsed = project.parse_dbt_project_yml(fixture)
    assert.are.equal("jaffle_shop", parsed.name)
  end)

  it("returns nil when the directory has no dbt_project.yml", function()
    assert.is_nil(project.parse_dbt_project_yml(repo_root .. "/tests"))
  end)

  it("returns nil for a nil or empty root", function()
    assert.is_nil(project.parse_dbt_project_yml(nil))
    assert.is_nil(project.parse_dbt_project_yml(""))
  end)
end)

describe("project.find_root", function()
  it("resolves upward from a real model file", function()
    assert.are.equal(fixture, project.find_root(fixture .. "/models/marts/customers.sql"))
  end)

  it("resolves upward from a nested staging model", function()
    assert.are.equal(fixture, project.find_root(fixture .. "/models/staging/stg_orders.sql"))
  end)

  it("resolves from a directory inside the project", function()
    assert.are.equal(fixture, project.find_root(fixture .. "/models/marts"))
  end)

  it("resolves from the project root itself", function()
    assert.are.equal(fixture, project.find_root(fixture))
  end)

  it("tolerates a trailing slash", function()
    assert.are.equal(fixture, project.find_root(fixture .. "/"))
  end)

  it("returns nil when no dbt_project.yml exists above the start path", function()
    assert.is_nil(project.find_root("/tmp"))
  end)
end)

describe("project.target_dir", function()
  it("uses the project's own target-path", function()
    assert.are.equal(fixture .. "/target", project.target_dir(fixture))
  end)

  it("falls back to target when there is no dbt_project.yml", function()
    assert.are.equal(repo_root .. "/tests/target", project.target_dir(repo_root .. "/tests"))
  end)
end)

describe("project.model_name_from_path", function()
  it("returns the model name for a file under models/", function()
    assert.are.equal("customers", project.model_name_from_path(fixture .. "/models/marts/customers.sql", fixture))
  end)

  it("accepts a path relative to the project root", function()
    assert.are.equal("stg_orders", project.model_name_from_path("models/staging/stg_orders.sql", fixture))
  end)

  it("returns nil for a file outside models/", function()
    assert.is_nil(project.model_name_from_path(fixture .. "/dbt_project.yml", fixture))
  end)

  it("returns nil for a seed", function()
    assert.is_nil(project.model_name_from_path(fixture .. "/seeds/raw_customers.csv", fixture))
  end)

  it("returns nil for nil or empty input", function()
    assert.is_nil(project.model_name_from_path(nil, fixture))
    assert.is_nil(project.model_name_from_path("", fixture))
  end)
end)

describe("project.get_root", function()
  it("finds the root from a buffer opened on a fixture model", function()
    local bufnr = vim.fn.bufadd(fixture .. "/models/marts/orders.sql")
    vim.fn.bufload(bufnr)
    assert.are.equal(fixture, project.get_root(bufnr))
  end)

  it("returns the same answer on a second, memoized call", function()
    local bufnr = vim.fn.bufadd(fixture .. "/models/marts/orders.sql")
    vim.fn.bufload(bufnr)
    assert.are.equal(fixture, project.get_root(bufnr))
    assert.are.equal(fixture, project.get_root(bufnr))
  end)
end)
