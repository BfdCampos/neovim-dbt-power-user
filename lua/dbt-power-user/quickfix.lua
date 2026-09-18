-- Turns the latest run_results.json into a quickfix list.

local manifest = require("dbt-power-user.manifest")
local util = require("dbt-power-user.util")

local M = {}

-- Mirrors dbt's own interpret_results: "success", "pass" and "warn" are clean, the rest
-- of the statuses it can report are failures.
local FAILURE_STATUSES = {
  ["error"] = true,
  ["fail"] = true,
  ["runtime error"] = true,
  ["skipped"] = true,
  ["partial success"] = true,
}

-- Nodes live under several top-level keys and a failing test is not in the graph
-- projection, so the raw manifest is searched rather than manifest.graph().
local NODE_COLLECTIONS = { "nodes", "sources", "unit_tests" }

function M.is_failure(status)
  if type(status) ~= "string" then
    return false
  end
  return FAILURE_STATUSES[status:lower()] == true
end

-- JSON null decodes to vim.NIL, which is truthy, so every artifact field is guarded.
local function as_string(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function find_node(data, unique_id)
  for _, key in ipairs(NODE_COLLECTIONS) do
    local group = data[key]
    if type(group) == "table" then
      local node = group[unique_id]
      if type(node) == "table" then
        return node
      end
    end
  end
  return nil
end

local function one_line(text)
  return (text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sort_entries(entries)
  table.sort(entries, function(a, b)
    local a_name, b_name = a.filename or "", b.filename or ""
    if a_name ~= b_name then
      return a_name < b_name
    end
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    if a.col ~= b.col then
      return a.col < b.col
    end
    return a.text < b.text
  end)
end

-- Failing results as quickfix entries, without touching the editor, so this is safe to
-- call from anywhere and is the part worth testing directly.
function M.entries(root_dir)
  local run_results = manifest.load_run_results(root_dir)
  local results = run_results and run_results.results
  if type(results) ~= "table" then
    return nil
  end

  local data = manifest.load(root_dir) or {}
  local entries = {}

  for _, result in ipairs(results) do
    if type(result) == "table" and M.is_failure(result.status) then
      local unique_id = as_string(result.unique_id)
      local node = unique_id and find_node(data, unique_id)
      local path = node and as_string(node.original_file_path)
      local text = as_string(result.message) or as_string(result.status) or "failed"
      local entry = { lnum = 1, col = 1, type = "E" }

      if path then
        entry.filename = util.path_join(root_dir, path)
      elseif unique_id then
        text = unique_id .. ": " .. text
      end
      entry.text = one_line(text)

      entries[#entries + 1] = entry
    end
  end

  sort_entries(entries)
  return entries
end

function M.populate_from_run_results(root_dir)
  local entries = M.entries(root_dir)
  if not entries then
    return nil
  end

  util.schedule(function()
    local list = {}
    for index, entry in ipairs(entries) do
      local item = { lnum = entry.lnum, col = entry.col, text = entry.text, type = entry.type }
      -- A quickfix item takes bufnr or filename, never both.
      local bufnr = entry.filename and vim.fn.bufnr(entry.filename) or -1
      if bufnr > 0 then
        item.bufnr = bufnr
      elseif entry.filename then
        item.filename = entry.filename
      end
      list[index] = item
    end

    vim.fn.setqflist(list, "r")
    vim.cmd("doautocmd QuickFixCmdPost")
  end)

  return entries
end

return M
