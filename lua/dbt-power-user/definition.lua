-- Go-to-definition for ref()/source()/macro calls in dbt buffers, plus the shared
-- "what is under the cursor" resolver that hover.lua also uses.

local extract = require("dbt-power-user.extract")
local manifest = require("dbt-power-user.manifest")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

-- ref() can point at any of these; models win when a name is ambiguous.
local REF_TYPES = { "model", "seed", "snapshot" }
local REF_RANK = { model = 1, seed = 2, snapshot = 3 }

-- Byte offsets from extract.lua index into the buffer joined with "\n", so the cursor
-- offset has to be computed against that same joined string rather than via
-- nvim_buf_get_offset (which counts line endings per 'fileformat').
local function text_and_offset(bufnr, row, col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local offset = 0
  for i = 1, math.min(row - 1, #lines) do
    offset = offset + #lines[i] + 1
  end
  return table.concat(lines, "\n"), offset + col + 1
end

local function macro_candidate(line, col)
  local cursor = col + 1
  local init = 1
  while true do
    local s, e, word = line:find("([%w_][%w_%.]*)", init)
    if not s or s > cursor then
      return nil
    end
    if cursor <= e + 1 then
      if line:sub(e + 1, e + 1) == "(" then
        return word
      end
      return nil
    end
    init = e + 1
  end
end

local function ref_unique_id(root_dir, call)
  local graph = manifest.graph(root_dir)
  local best, best_rank
  for unique_id, node in pairs(graph.nodes) do
    local rank = REF_RANK[node.resource_type]
    local matches = rank and node.name == call.name and (not call.pkg or node.package_name == call.pkg)
    if matches and (not best_rank or rank < best_rank or (rank == best_rank and unique_id < best)) then
      best, best_rank = unique_id, rank
    end
  end
  return best
end

local function source_unique_id(root_dir, call)
  local tables = manifest.sources(root_dir)[call.source_name]
  return tables and tables[call.table_name] or nil
end

local function manifest_node(root_dir, unique_id)
  local artifact = manifest.load(root_dir)
  if not artifact then
    return nil
  end
  local nodes = type(artifact.nodes) == "table" and artifact.nodes[unique_id]
  local sources = type(artifact.sources) == "table" and artifact.sources[unique_id]
  return nodes or sources or nil
end

local function resolution(root_dir, kind, unique_id, node)
  if not node then
    return nil
  end
  local relative = type(node.original_file_path) == "string" and node.original_file_path or nil
  return {
    kind = kind,
    root_dir = root_dir,
    unique_id = unique_id,
    node = node,
    name = node.name,
    path = relative and util.path_join(root_dir, relative) or nil,
  }
end

-- row is 1-based, col is 0-based, matching nvim_win_get_cursor.
function M.resolve_at(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local root_dir = project.get_root(bufnr)
  if not root_dir then
    return nil
  end

  local text, offset = text_and_offset(bufnr, row, col)
  local call = extract.call_under_cursor(text, offset)

  if call and call.kind == "ref" then
    local unique_id = ref_unique_id(root_dir, call)
    return unique_id and resolution(root_dir, "ref", unique_id, manifest_node(root_dir, unique_id)) or nil
  end

  if call and call.kind == "source" then
    local unique_id = source_unique_id(root_dir, call)
    return unique_id and resolution(root_dir, "source", unique_id, manifest_node(root_dir, unique_id)) or nil
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  local candidate = line and macro_candidate(line, col)
  if candidate then
    local macro = manifest.macro_lookup(root_dir, candidate)
    if macro then
      return resolution(root_dir, "macro", macro.unique_id, macro)
    end
  end

  return nil
end

function M.resolve_under_cursor(winid)
  winid = winid or 0
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  return M.resolve_at(bufnr, cursor[1], cursor[2])
end

function M.goto_under_cursor()
  local found = M.resolve_under_cursor()
  if not found or not found.path then
    return util.notify("No definition found", vim.log.levels.WARN)
  end
  util.schedule(function()
    vim.cmd.edit(found.path)
  end)
end

-- Fallback for <C-]>, where the cursor may already have moved off the call: resolve the
-- tag pattern as a model, "source.table" or macro name.
local function resolve_pattern(root_dir, pattern)
  for _, resource_type in ipairs(REF_TYPES) do
    local unique_id = manifest.find_node_by_name(root_dir, pattern, resource_type)
    if unique_id then
      return resolution(root_dir, "ref", unique_id, manifest_node(root_dir, unique_id))
    end
  end

  local unique_id = manifest.find_node_by_name(root_dir, pattern, "source")
  if unique_id then
    return resolution(root_dir, "source", unique_id, manifest_node(root_dir, unique_id))
  end

  local macro = manifest.macro_lookup(root_dir, pattern)
  if macro then
    return resolution(root_dir, "macro", macro.unique_id, macro)
  end

  return nil
end

function M.tagfunc(pattern, _, _)
  local found = M.resolve_under_cursor()
  if not found then
    local root_dir = project.get_root(vim.api.nvim_get_current_buf())
    found = root_dir and pattern and pattern ~= "" and resolve_pattern(root_dir, pattern) or nil
  end
  if not found or not found.path then
    return {}
  end
  return { { name = found.name or pattern, filename = found.path, cmd = "1" } }
end

function M.setup_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.bo[bufnr].tagfunc = "v:lua.require'dbt-power-user.definition'.tagfunc"
end

return M
