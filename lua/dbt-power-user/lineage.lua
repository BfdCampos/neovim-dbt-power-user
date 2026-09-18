-- Upstream/downstream lineage: graph walks over manifest.graph(), plus a top-to-
-- bottom flowchart view (lua/dbt-power-user/flowchart.lua) and a snacks picker.

local config = require("dbt-power-user.config")
local flowchart = require("dbt-power-user.flowchart")
local manifest = require("dbt-power-user.manifest")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

local function default_depth(max_depth)
  if type(max_depth) == "number" and max_depth >= 0 then
    return max_depth
  end
  local lineage = config.options.lineage or {}
  return lineage.max_depth or 5
end

local function entry(node)
  return {
    unique_id = node.unique_id,
    name = node.name,
    resource_type = node.resource_type,
    materialized = node.materialized,
    children = {},
  }
end

-- Breadth-first, so every reachable node lands once at its shallowest depth. That
-- keeps a diamond (stg_orders feeding both orders and order_items) from being walked
-- twice, bounds the walk on a wide DAG, and leaves unique_id usable as a node id.
local function walk(root_dir, unique_id, edge, max_depth)
  local graph = manifest.graph(root_dir)
  local start = graph.nodes[unique_id]
  if not start then
    return nil
  end

  local root = entry(start)
  local visited = { [unique_id] = true }
  local queue = { { tree = root, unique_id = unique_id, depth = 0 } }
  local head = 1

  while head <= #queue do
    local current = queue[head]
    head = head + 1

    if current.depth < max_depth then
      for _, next_id in ipairs(graph[edge][current.unique_id] or {}) do
        local node = graph.nodes[next_id]
        if node and not visited[next_id] then
          visited[next_id] = true
          local child = entry(node)
          table.insert(current.tree.children, child)
          queue[#queue + 1] = { tree = child, unique_id = next_id, depth = current.depth + 1 }
        end
      end
    end
  end

  return root
end

function M.ancestors(root_dir, unique_id, max_depth)
  return walk(root_dir, unique_id, "parents", default_depth(max_depth))
end

function M.descendants(root_dir, unique_id, max_depth)
  return walk(root_dir, unique_id, "children", default_depth(max_depth))
end

local function flatten(tree, depth, out)
  out = out or {}
  depth = depth or 0
  out[#out + 1] = { tree = tree, depth = depth }
  for _, child in ipairs(tree.children) do
    flatten(child, depth + 1, out)
  end
  return out
end

local function resolve(unique_id)
  local root_dir = config.options.project_dir or project.get_root(0)
  if not root_dir then
    util.notify("no dbt project found, could not locate dbt_project.yml", vim.log.levels.WARN)
    return nil
  end

  if not unique_id or unique_id == "" then
    unique_id = manifest.find_node_by_path(root_dir, vim.api.nvim_buf_get_name(0))
  end
  if not unique_id then
    util.notify("current buffer is not a dbt node", vim.log.levels.WARN)
    return nil
  end

  return root_dir, unique_id
end

local function node_file(root_dir, unique_id)
  local node = manifest.graph(root_dir).nodes[unique_id]
  if not node or not node.original_file_path then
    return nil
  end
  return util.path_join(root_dir, node.original_file_path)
end

local function node_detail(node)
  if node.resource_type == "source" then
    return "source" -- dbt doesn't build a source, "materialized" is meaningless for it
  end
  local kind = node.resource_type or "?"
  if node.materialized then
    kind = kind .. " · " .. node.materialized
  end
  return kind
end

-- Union of the ancestor tree, the descendant tree, and the target itself into one
-- flowchart-ready node/edge list, with EVERY real edge between visible nodes (not
-- just the tree's own BFS-shortest-path edges -- a node can have more real parents
-- than the single one that happened to place it in the tree walk).
local function flow_graph(root_dir, target, max_depth)
  local graph = manifest.graph(root_dir)
  if not graph.nodes[target] then
    return nil
  end

  local visible = { [target] = true }
  for _, tree in ipairs({ M.ancestors(root_dir, target, max_depth), M.descendants(root_dir, target, max_depth) }) do
    for _, flat in ipairs(flatten(tree)) do
      visible[flat.tree.unique_id] = true
    end
  end

  local nodes, edges = {}, {}
  for id in pairs(visible) do
    local node = graph.nodes[id]
    nodes[#nodes + 1] = { id = id, label = node.name or id, detail = node_detail(node) }
  end
  for id in pairs(visible) do
    for _, parent_id in ipairs(graph.parents[id] or {}) do
      if visible[parent_id] then
        edges[#edges + 1] = { from = parent_id, to = id }
      end
    end
  end

  return nodes, edges
end

function M.show_tree(unique_id)
  local root_dir, target = resolve(unique_id)
  if not root_dir then
    return nil
  end

  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then
    util.notify("nui.nvim is required for the lineage view", vim.log.levels.ERROR)
    return nil
  end

  local node = manifest.graph(root_dir).nodes[target]
  local title = " Lineage: " .. ((node and node.name) or target) .. " "
  local origin = vim.api.nvim_get_current_win()

  local popup = Popup({
    enter = true,
    focusable = true,
    position = "50%",
    size = { width = "90%", height = "80%" },
    border = { style = "rounded", text = { top = title, top_align = "center" } },
    buf_options = { modifiable = false, readonly = true },
    win_options = { wrap = false, cursorline = true, sidescrolloff = 4 },
  })

  popup:mount()

  -- Multiple nodes routinely share one buffer line (every sibling in the same
  -- layer, in either orientation), so "which file does <CR> open" has to be
  -- resolved from the exact (line, column) box the cursor is inside, not just the
  -- line number -- line-only lookup silently opens whichever node's box happened to
  -- be written into the lookup table last.
  local boxes = {}

  local function render()
    local nodes, edges = flow_graph(root_dir, target)
    local direction = (config.options.lineage or {}).direction
    local result = nodes and #nodes > 0 and flowchart.build(nodes, edges, { direction = direction })
    local lines = result and result.lines or { "(no lineage to show)" }
    boxes = (result and result.boxes) or {}

    vim.bo[popup.bufnr].readonly = false
    vim.bo[popup.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
    vim.bo[popup.bufnr].modifiable = false
    vim.bo[popup.bufnr].readonly = true
  end

  render()

  local function open(keep_focus)
    local cursor = vim.api.nvim_win_get_cursor(popup.winid)
    local lnum, col = cursor[1], cursor[2]
    local file
    for _, box in ipairs(boxes) do
      if box.line == lnum and col >= box.col_start and col <= box.col_end then
        file = node_file(root_dir, box.id)
        break
      end
    end
    if not file then
      return false
    end
    if keep_focus and vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_win_call(origin, function()
        vim.cmd.edit(file)
      end)
      return true
    end
    popup:unmount()
    vim.cmd.edit(file)
    return true
  end

  popup:map("n", "<CR>", function()
    open(false)
  end, { noremap = true, nowait = true })

  popup:map("n", "o", function()
    open(true)
  end, { noremap = true, nowait = true })

  popup:map("n", "R", function()
    manifest.invalidate(root_dir)
    render()
  end, { noremap = true, nowait = true })

  for _, key in ipairs({ "q", "<Esc>" }) do
    popup:map("n", key, function()
      popup:unmount()
    end, { noremap = true, nowait = true })
  end

  return popup
end

function M.show_picker(unique_id, direction)
  local root_dir, target = resolve(unique_id)
  if not root_dir then
    return nil
  end

  local snacks = rawget(_G, "Snacks")
  local picker = type(snacks) == "table" and snacks.picker or nil
  if not picker then
    util.notify("snacks.nvim with the picker enabled is required for the lineage picker", vim.log.levels.ERROR)
    return nil
  end

  local descending = direction == "descendants"
  local tree = descending and M.descendants(root_dir, target) or M.ancestors(root_dir, target)
  if not tree then
    util.notify("no lineage found for " .. target, vim.log.levels.WARN)
    return nil
  end

  local items = {}
  for _, flat in ipairs(flatten(tree)) do
    items[#items + 1] = {
      text = flat.tree.name or flat.tree.unique_id,
      file = node_file(root_dir, flat.tree.unique_id),
      depth = flat.depth,
      resource_type = flat.tree.resource_type,
      unique_id = flat.tree.unique_id,
    }
  end

  local node = manifest.graph(root_dir).nodes[target]
  return picker.pick({
    source = "dbt_lineage",
    title = (descending and "dbt downstream: " or "dbt upstream: ") .. ((node and node.name) or target),
    items = items,
    preview = (config.options.picker or {}).preview and "file" or "none",
    format = function(item)
      return {
        { string.rep("  ", item.depth) },
        { item.text, "SnacksPickerLabel" },
        { "  " .. (item.resource_type or ""), "SnacksPickerComment" },
      }
    end,
    confirm = function(instance, item)
      instance:close()
      if item and item.file then
        vim.cmd.edit(item.file)
      end
    end,
  })
end

return M
