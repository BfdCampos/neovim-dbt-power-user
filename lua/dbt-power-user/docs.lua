-- dbt docs generate / open, plus a schema.yml scaffold built from the catalog.

local config = require("dbt-power-user.config")
local job = require("dbt-power-user.job")
local manifest = require("dbt-power-user.manifest")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

local function root_dir()
  return config.options.project_dir or project.find_root()
end

local function open_scratch(name, lines, filetype)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = filetype
  vim.bo[bufnr].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
  vim.cmd.split()
  vim.api.nvim_win_set_buf(0, bufnr)
  return bufnr
end

function M.generate()
  util.notify("dbt docs generate: running")
  return job.run_dbt({ "docs", "generate" }, {
    on_exit = function(res)
      if res.code == 0 then
        local root = root_dir()
        if root then
          manifest.invalidate(root)
        end
        util.notify("dbt docs generate: done")
      else
        local err = res.stderr
        util.notify((err and err ~= "" and err) or "dbt docs generate failed", vim.log.levels.ERROR)
      end
    end,
  })
end

function M.open()
  local root = root_dir()
  if not root then
    return util.notify("no dbt project found", vim.log.levels.WARN)
  end

  local index = util.path_join(project.target_dir(root), "index.html")
  if not vim.uv.fs_stat(index) then
    return util.notify("no docs at " .. index .. ", run :DbtDocsGenerate first", vim.log.levels.WARN)
  end

  pcall(vim.ui.open, index)
end

-- Columns are emitted in warehouse order (catalog carries an index) so the scaffold
-- lines up with what `select *` actually returns.
local function catalog_columns(catalog_node)
  local columns = {}
  for key, column in pairs(type(catalog_node.columns) == "table" and catalog_node.columns or {}) do
    if type(column) == "table" then
      columns[#columns + 1] = {
        name = (type(column.name) == "string" and column.name) or key,
        index = tonumber(column.index) or math.huge,
      }
    end
  end
  table.sort(columns, function(a, b)
    if a.index ~= b.index then
      return a.index < b.index
    end
    return a.name < b.name
  end)
  return columns
end

-- Deliberately a scratch buffer rather than a write into the user's real schema.yml:
-- merging YAML without clobbering their comments and ordering is out of scope for v1.
function M.generate_yaml_scaffold(model_name)
  if not model_name or model_name == "" then
    return util.notify("no model name given", vim.log.levels.ERROR)
  end

  local root = root_dir()
  if not root then
    return util.notify("no dbt project found", vim.log.levels.WARN)
  end

  local unique_id = manifest.find_node_by_name(root, model_name, "model")
  if not unique_id then
    return util.notify("no such model: " .. model_name, vim.log.levels.WARN)
  end

  local catalog = manifest.load_catalog(root)
  local catalog_node = catalog and type(catalog.nodes) == "table" and catalog.nodes[unique_id]
  if type(catalog_node) ~= "table" then
    return util.notify(
      model_name .. " is not in the catalog, run `dbt docs generate` first",
      vim.log.levels.WARN
    )
  end

  local lines = {
    "version: 2",
    "",
    "models:",
    "  - name: " .. model_name,
    '    description: ""',
    "    columns:",
  }
  for _, column in ipairs(catalog_columns(catalog_node)) do
    lines[#lines + 1] = "      - name: " .. column.name
    lines[#lines + 1] = '        description: ""'
  end

  return open_scratch("dbt-scaffold://" .. model_name .. ".yml", lines, "yaml")
end

return M
