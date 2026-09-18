-- Local-only model healthchecks, using the same four messages as the VSCode extension.

local manifest = require("dbt-power-user.manifest")

local M = {}

M.ns = vim.api.nvim_create_namespace("dbt-power-user/diagnostics")

local SEVERITY = vim.diagnostic.severity.HINT

local MESSAGES = {
  no_docs = "Documentation missing for model: %s",
  not_built = "Model %s does not exist in the database",
  undocumented_column = "Column %s is undocumented in model: %s",
  missing_column = "Column %s listed in model %s is not found in the database.",
}

local function as_table(value)
  if type(value) == "table" then
    return value
  end
  return nil
end

local function sorted_keys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Both manifest nodes and catalog nodes key columns by name and repeat the name
-- inside the entry. Compare case-insensitively (warehouses disagree on casing) but
-- report the name as the artifact spelled it.
local function column_names(columns)
  local names = {}
  for key, column in pairs(as_table(columns) or {}) do
    local name = (as_table(column) and type(column.name) == "string" and column.name) or key
    if type(name) == "string" and name ~= "" then
      names[name:lower()] = name
    end
  end
  return names
end

function M.check(root_dir)
  local diagnostics = {}
  if not root_dir or root_dir == "" then
    return diagnostics
  end

  local data = manifest.load(root_dir)
  local nodes = data and as_table(data.nodes)
  if not nodes then
    return diagnostics
  end

  -- No catalog at all means no information about the warehouse, which is different
  -- from a catalog that simply has no entry for one model.
  local catalog = manifest.load_catalog(root_dir)
  local catalog_nodes = catalog and as_table(catalog.nodes)

  local function add(unique_id, name, message, column)
    diagnostics[#diagnostics + 1] = {
      unique_id = unique_id,
      name = name,
      message = message,
      severity = SEVERITY,
      column = column,
    }
  end

  for _, unique_id in ipairs(sorted_keys(nodes)) do
    local node = as_table(nodes[unique_id])
    if node and node.resource_type == "model" then
      local name = (type(node.name) == "string" and node.name) or unique_id

      if type(node.patch_path) ~= "string" or node.patch_path == "" then
        add(unique_id, name, MESSAGES.no_docs:format(name))
      end

      if catalog_nodes then
        local built_node = as_table(catalog_nodes[unique_id])
        if not built_node then
          add(unique_id, name, MESSAGES.not_built:format(name))
        else
          local documented = column_names(node.columns)
          local built = column_names(built_node.columns)

          for _, key in ipairs(sorted_keys(built)) do
            if not documented[key] then
              add(unique_id, name, MESSAGES.undocumented_column:format(built[key], name), built[key])
            end
          end

          for _, key in ipairs(sorted_keys(documented)) do
            if not built[key] then
              add(unique_id, name, MESSAGES.missing_column:format(documented[key], name), documented[key])
            end
          end
        end
      end
    end
  end

  return diagnostics
end

-- Column diagnostics are far more useful anchored to where the column is actually
-- selected, so look for the name as a whole word before falling back to line one.
local function locate(lines, word)
  if not word then
    return 0, 0, 0
  end
  local pattern = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
  for index, line in ipairs(lines) do
    local from, to = line:find(pattern)
    if from then
      return index - 1, from - 1, to
    end
  end
  return 0, 0, 0
end

function M.refresh_buffer(bufnr, root_dir)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local unique_id = path ~= "" and manifest.find_node_by_path(root_dir, path) or nil
  if not unique_id then
    vim.diagnostic.reset(M.ns, bufnr)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local entries = {}
  for _, diagnostic in ipairs(M.check(root_dir)) do
    if diagnostic.unique_id == unique_id then
      local lnum, col, end_col = locate(lines, diagnostic.column)
      entries[#entries + 1] = {
        bufnr = bufnr,
        lnum = lnum,
        col = col,
        end_lnum = lnum,
        end_col = end_col,
        message = diagnostic.message,
        severity = diagnostic.severity,
        source = "dbt",
      }
    end
  end

  vim.diagnostic.set(M.ns, bufnr, entries, {})
  return entries
end

return M
