-- snacks pickers over the manifest: models, sources, macros, the action palette and
-- the latest run results.

local config = require("dbt-power-user.config")
local manifest = require("dbt-power-user.manifest")
local project = require("dbt-power-user.project")
local quickfix = require("dbt-power-user.quickfix")
local util = require("dbt-power-user.util")

local M = {}

local unpack = unpack or table.unpack

local function snacks()
  local loaded = rawget(_G, "Snacks")
  local picker = type(loaded) == "table" and loaded.picker or nil
  if not picker then
    util.notify("snacks.nvim with the picker enabled is required for the dbt pickers", vim.log.levels.ERROR)
    return nil
  end
  return picker
end

local function root_dir()
  local root = config.options.project_dir or project.get_root(0)
  if not root then
    util.notify("no dbt project found, could not locate dbt_project.yml", vim.log.levels.WARN)
    return nil
  end
  return root
end

local function node_file(root, original_file_path)
  if not original_file_path then
    return nil
  end
  return util.path_join(root, original_file_path)
end

local function open_file(instance, item)
  instance:close()
  if item and item.file then
    vim.cmd.edit(item.file)
  end
end

local function preview_mode()
  return (config.options.picker or {}).preview and "file" or "none"
end

local function pick_nodes(source, title, resource_type, text_for)
  local picker = snacks()
  local root = picker and root_dir()
  if not root then
    return nil
  end

  local items = {}
  for _, node in pairs(manifest.graph(root).nodes) do
    if node.resource_type == resource_type then
      items[#items + 1] = {
        text = text_for(node),
        file = node_file(root, node.original_file_path),
        unique_id = node.unique_id,
        detail = node.materialized,
        package_name = node.package_name,
      }
    end
  end

  if #items == 0 then
    util.notify("no " .. resource_type .. "s in the manifest, try `dbt parse`", vim.log.levels.WARN)
    return nil
  end

  table.sort(items, function(a, b)
    return a.text < b.text
  end)

  return picker.pick({
    source = source,
    title = title,
    items = items,
    preview = preview_mode(),
    format = function(item)
      return {
        { item.text, "SnacksPickerLabel" },
        { "  " .. (item.detail or ""), "SnacksPickerComment" },
      }
    end,
    confirm = open_file,
  })
end

function M.models()
  return pick_nodes("dbt_models", "dbt models", "model", function(node)
    return node.name
  end)
end

function M.sources()
  return pick_nodes("dbt_sources", "dbt sources", "source", function(node)
    if node.source_name then
      return node.source_name .. "." .. node.name
    end
    return node.name
  end)
end

function M.macros()
  local picker = snacks()
  local root = picker and root_dir()
  if not root then
    return nil
  end

  local data = manifest.load(root)
  local macros = data and type(data.macros) == "table" and data.macros or nil
  if not macros then
    util.notify("no manifest found, try `dbt parse`", vim.log.levels.WARN)
    return nil
  end

  local own = data.metadata and data.metadata.project_name
  local items = {}
  for unique_id, macro in pairs(macros) do
    if type(macro) == "table" and type(macro.name) == "string" then
      local package_name = macro.package_name
      items[#items + 1] = {
        -- package-qualify anything outside the root project so typing the package narrows
        text = (package_name and package_name ~= own) and (package_name .. "." .. macro.name) or macro.name,
        file = node_file(root, macro.original_file_path),
        unique_id = unique_id,
        detail = package_name,
      }
    end
  end

  table.sort(items, function(a, b)
    return a.text < b.text
  end)

  return picker.pick({
    source = "dbt_macros",
    title = "dbt macros",
    items = items,
    preview = preview_mode(),
    format = function(item)
      return {
        { item.text, "SnacksPickerLabel" },
        { "  " .. (item.detail or ""), "SnacksPickerComment" },
      }
    end,
    confirm = open_file,
  })
end

-- Lazily required so the palette never couples module load order, and so commands.lua
-- is free to open this picker itself.
local function call(module, fn, ...)
  local args = { ... }
  return function()
    require("dbt-power-user." .. module)[fn](unpack(args))
  end
end

local function lineage(direction)
  return function()
    local lineage_module = require("dbt-power-user.lineage")
    if direction then
      lineage_module.show_picker(nil, direction)
    else
      lineage_module.show_tree(nil)
    end
  end
end

local ACTIONS = {
  { key = "r", label = "Run current model", fn = call("commands", "run_model", "current") },
  { key = "R", label = "Run current model and downstream", fn = call("commands", "run_model", "downstream") },
  { key = "u", label = "Run upstream and current model", fn = call("commands", "run_model", "upstream") },
  { key = "b", label = "Build current model", fn = call("commands", "build_model", "current") },
  { key = "t", label = "Test current model", fn = call("commands", "test_model") },
  { key = "c", label = "Compile and preview current model", fn = call("compile", "preview") },
  { key = "p", label = "Preview query results", fn = call("show", "preview_query") },
  { key = "l", label = "Lineage tree", fn = lineage(nil) },
  { key = "L", label = "Lineage picker (upstream)", fn = lineage("ancestors") },
  { label = "Lineage picker (downstream)", fn = lineage("descendants") },
  { key = "g", label = "Go to definition under cursor", fn = call("definition", "goto_under_cursor") },
  { key = "k", label = "Hover under cursor", fn = call("hover", "show") },
  { key = "m", label = "Models picker", fn = call("picker", "models") },
  { key = "s", label = "Sources picker", fn = call("picker", "sources") },
  { key = "M", label = "Macros picker", fn = call("picker", "macros") },
  { key = "h", label = "Run history (latest run results)", fn = call("picker", "run_history") },
  { key = "D", label = "Toggle defer to prod", fn = call("defer", "toggle") },
  { key = "o", label = "Open dbt docs in browser", fn = call("docs", "open") },
  { key = "G", label = "Generate dbt docs", fn = call("docs", "generate") },
}

-- Exposed so keymaps.lua can wire the same action list as real leader mappings
-- instead of maintaining a second, driftable copy.
M.ACTIONS = ACTIONS

function M.actions()
  local picker = snacks()
  if not picker then
    return nil
  end

  local prefix = config.options.prefix or ""
  local items = {}
  for _, action in ipairs(ACTIONS) do
    items[#items + 1] = {
      text = action.label,
      keymap_hint = action.key and (prefix .. action.key) or "",
      fn = action.fn,
    }
  end

  return picker.pick({
    source = "dbt_actions",
    title = "dbt actions",
    items = items,
    preview = "none",
    format = function(item)
      return {
        { item.keymap_hint, "SnacksPickerSpecial" },
        { "  " .. item.text, "SnacksPickerLabel" },
      }
    end,
    confirm = function(instance, item)
      instance:close()
      if item and item.fn then
        -- back on the main loop so the picker window is gone before the action draws
        vim.schedule(item.fn)
      end
    end,
  })
end

function M.run_history(root)
  local picker = snacks()
  if not picker then
    return nil
  end

  root = root or root_dir()
  if not root then
    return nil
  end

  local data = manifest.load_run_results(root)
  local results = data and type(data.results) == "table" and data.results or nil
  if not results or #results == 0 then
    util.notify("no run results found, run dbt first", vim.log.levels.WARN)
    return nil
  end

  local graph = manifest.graph(root)
  local nodes = manifest.load(root)
  nodes = nodes and type(nodes.nodes) == "table" and nodes.nodes or {}

  local items = {}
  for index, result in ipairs(results) do
    local unique_id = type(result.unique_id) == "string" and result.unique_id or nil
    local status = type(result.status) == "string" and result.status or "unknown"
    local raw = unique_id and nodes[unique_id]
    local name = (unique_id and graph.nodes[unique_id] and graph.nodes[unique_id].name)
      or (type(raw) == "table" and raw.name)
      or unique_id
      or "result " .. index

    local original_file_path = (unique_id and graph.nodes[unique_id] and graph.nodes[unique_id].original_file_path)
      or (type(raw) == "table" and type(raw.original_file_path) == "string" and raw.original_file_path)
      or nil

    items[#items + 1] = {
      text = name,
      file = node_file(root, original_file_path),
      unique_id = unique_id,
      status = status,
      failed = quickfix.is_failure(status),
      order = index,
      message = type(result.message) == "string" and result.message or nil,
    }
  end

  table.sort(items, function(a, b)
    if a.failed ~= b.failed then
      return a.failed
    end
    if a.text ~= b.text then
      return a.text < b.text
    end
    return a.order < b.order
  end)

  local failures = 0
  for _, item in ipairs(items) do
    if item.failed then
      failures = failures + 1
    end
  end

  return picker.pick({
    source = "dbt_run_history",
    title = ("dbt run results (%d/%d failed)"):format(failures, #items),
    items = items,
    preview = preview_mode(),
    format = function(item)
      return {
        { item.status, item.failed and "SnacksPickerDiagnosticError" or "SnacksPickerComment" },
        { "  " .. item.text, "SnacksPickerLabel" },
        { item.message and ("  " .. item.message) or "", "SnacksPickerComment" },
      }
    end,
    confirm = open_file,
  })
end

return M
