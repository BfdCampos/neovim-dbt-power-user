-- Scaffold a staging model over a source, as an unsaved buffer the user places themselves.

local config = require("dbt-power-user.config")
local manifest = require("dbt-power-user.manifest")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

local function model_name(table_name)
  local opts = config.options.create_model or {}
  local values = {
    prefix = opts.prefix or "stg",
    table = table_name,
  }
  local name = (opts.template or "{prefix}_{table}"):gsub("{(%w+)}", function(key)
    return values[key] or ("{" .. key .. "}")
  end)
  return name
end

function M.from_source(source_name, table_name)
  if not source_name or source_name == "" or not table_name or table_name == "" then
    return util.notify("a source name and a table name are both required", vim.log.levels.ERROR)
  end

  local root = config.options.project_dir or project.find_root()
  if root then
    local tables = manifest.sources(root)[source_name]
    if not tables or not tables[table_name] then
      util.notify(
        ("source `%s.%s` is not in the manifest, scaffolding anyway"):format(source_name, table_name),
        vim.log.levels.WARN
      )
    end
  end

  local name = model_name(table_name)
  local bufnr = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, bufnr, name .. ".sql")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    ("select * from {{ source('%s', '%s') }}"):format(source_name, table_name),
    "",
  })
  vim.bo[bufnr].filetype = "sql"

  vim.cmd.split()
  vim.api.nvim_win_set_buf(0, bufnr)
  util.notify(("scaffolded %s.sql, save it wherever it belongs"):format(name))
  return bufnr
end

return M
