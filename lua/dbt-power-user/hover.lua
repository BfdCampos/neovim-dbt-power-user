-- Markdown hover for the dbt node under the cursor, using definition.lua's resolver.

local definition = require("dbt-power-user.definition")
local manifest = require("dbt-power-user.manifest")
local util = require("dbt-power-user.util")

local M = {}

local function description(node)
  local text = node.description
  if type(text) ~= "string" then
    return nil
  end
  text = vim.trim(text)
  return text ~= "" and text or nil
end

local function catalog_columns(found)
  local catalog = manifest.load_catalog(found.root_dir)
  if type(catalog) ~= "table" then
    return nil
  end
  for _, group in ipairs({ catalog.nodes, catalog.sources }) do
    local entry = type(group) == "table" and group[found.unique_id]
    if type(entry) == "table" and type(entry.columns) == "table" then
      return entry.columns
    end
  end
  return nil
end

-- Catalog columns carry the warehouse type and an ordinal; manifest columns carry the
-- docs. An absent catalog entry just means the node has not been built yet.
local function column_lines(found)
  local documented = type(found.node.columns) == "table" and found.node.columns or {}
  local built = catalog_columns(found)

  local ordered = {}
  if built then
    for name, column in pairs(built) do
      ordered[#ordered + 1] = { name = name, data_type = column.type, index = column.index or 0 }
    end
    table.sort(ordered, function(a, b)
      if a.index ~= b.index then
        return a.index < b.index
      end
      return a.name < b.name
    end)
  else
    for name, column in pairs(documented) do
      ordered[#ordered + 1] = { name = name, data_type = column.data_type }
    end
    table.sort(ordered, function(a, b)
      return a.name < b.name
    end)
  end

  local lines = {}
  for _, column in ipairs(ordered) do
    local entry = "- `" .. column.name .. "`"
    if type(column.data_type) == "string" and column.data_type ~= "" then
      entry = entry .. " (" .. column.data_type .. ")"
    end
    local doc = documented[column.name] and description(documented[column.name])
    if doc then
      entry = entry .. ": " .. doc:gsub("%s*\n%s*", " ")
    end
    lines[#lines + 1] = entry
  end
  return lines, built ~= nil
end

function M.markdown(found)
  local node = found.node
  local lines = { "# " .. (node.name or found.unique_id or "?") }

  local meta = { "`" .. (node.resource_type or found.kind) .. "`" }
  local config = type(node.config) == "table" and node.config or {}
  if found.kind == "ref" then
    meta[#meta + 1] = "materialized: `" .. (config.materialized or "view") .. "`"
  end
  if found.kind == "source" and type(node.source_name) == "string" then
    meta[#meta + 1] = "source: `" .. node.source_name .. "`"
  end
  local relation = {}
  for _, key in ipairs({ "database", "schema" }) do
    if type(node[key]) == "string" and node[key] ~= "" then
      relation[#relation + 1] = node[key]
    end
  end
  if #relation > 0 then
    meta[#meta + 1] = "`" .. table.concat(relation, ".") .. "`"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = table.concat(meta, " · ")

  local desc = description(node)
  if desc then
    lines[#lines + 1] = ""
    for _, line in ipairs(vim.split(desc, "\n")) do
      lines[#lines + 1] = line
    end
  end

  if found.kind ~= "macro" then
    local columns, built = column_lines(found)
    lines[#lines + 1] = ""
    if #columns > 0 then
      lines[#lines + 1] = "## Columns"
      vim.list_extend(lines, columns)
      if not built then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "_Not in the catalog yet, types unknown. Run `dbt docs generate`._"
      end
    else
      lines[#lines + 1] = "_No columns documented or catalogued._"
    end
  end

  if type(node.original_file_path) == "string" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "`" .. node.original_file_path .. "`"
  end

  return table.concat(lines, "\n")
end

function M.show()
  local found = definition.resolve_under_cursor()
  if not found then
    return util.notify("Nothing to hover under cursor", vim.log.levels.WARN)
  end
  local md = M.markdown(found)
  util.schedule(function()
    vim.lsp.util.open_floating_preview(vim.split(md, "\n"), "markdown", { border = "rounded" })
  end)
end

return M
