-- Pure ASCII layered-DAG renderer: nodes + "A feeds B" edges in, a flowchart (array
-- of text lines, plus a line->node-id map for jump-to-file) out. Zero "vim."
-- references -- testable under bare lua/luajit with no editor present.
--
-- Layering is longest-path-from-roots (the standard technique for drawing a DAG
-- without ever drawing an edge backward or sideways): a node's layer is one more
-- than the deepest layer among the nodes that feed it. A node whose two dependents
-- sit at very different distances from the root can still need an edge that skips
-- several layers -- those are drawn as a plain line "passing through" the layers
-- they skip, bending in only at the band just before where they land, rather than
-- inventing a dummy node per skipped layer.
--
-- Two orientations share this same layering: "vertical" (default) draws layers as
-- rows, top (sources) to bottom (the far side of the DAG); "horizontal" draws them
-- as columns, left to right. Pass opts.direction = "horizontal" for the latter.

local M = {}

local CONNECTOR_CHAR = {
  u = "│",
  d = "│",
  ud = "│",
  ur = "└",
  ul = "┘",
  dr = "┌",
  dl = "┐",
  ulr = "┴",
  dlr = "┬",
  udr = "├",
  udl = "┤",
  udlr = "┼",
  lr = "─",
}

local function bar_char(up, down, left, right)
  local key = (up and "u" or "") .. (down and "d" or "") .. (left and "l" or "") .. (right and "r" or "")
  return CONNECTOR_CHAR[key] or " "
end

local function build_graph(nodes, edges)
  local node_by_id, order = {}, {}
  for _, n in ipairs(nodes) do
    node_by_id[n.id] = n
    order[#order + 1] = n.id
  end

  local feeds_from = {}
  for _, id in ipairs(order) do
    feeds_from[id] = {}
  end
  for _, e in ipairs(edges) do
    if node_by_id[e.from] and node_by_id[e.to] and e.from ~= e.to then
      table.insert(feeds_from[e.to], e.from)
    end
  end

  return node_by_id, order, feeds_from
end

-- Longest path from a root (no predecessors) to each node.
local function compute_layers(order, feeds_from)
  local layer, visiting = {}, {}
  local function layer_of(id)
    if layer[id] then
      return layer[id]
    end
    if visiting[id] then
      layer[id] = 0 -- cycle guard; dbt graphs are acyclic, but never trust it blindly
      return 0
    end
    visiting[id] = true
    local max_pred = -1
    for _, p in ipairs(feeds_from[id]) do
      max_pred = math.max(max_pred, layer_of(p))
    end
    layer[id] = max_pred + 1
    visiting[id] = nil
    return layer[id]
  end
  for _, id in ipairs(order) do
    layer_of(id)
  end

  local max_layer = 0
  for _, id in ipairs(order) do
    max_layer = math.max(max_layer, layer[id])
  end
  local layers = {}
  for l = 0, max_layer do
    layers[l] = {}
  end
  for _, id in ipairs(order) do
    table.insert(layers[layer[id]], id)
  end

  return layer, max_layer, layers
end

-- Sort/position nodes along a "cross axis" (perpendicular to the layer axis): layer
-- 0 packs sequentially in `unit` steps; every later layer centers each node under
-- the average cross-position of its real predecessors (barycenter heuristic), then
-- only pushes siblings apart (never overlapping, order preserved) when they'd
-- collide, and finally shifts everything so the minimum position is exactly 0 (a
-- wide child centered under a narrow single parent can legitimately want a negative
-- position; clamping it during placement would silently overlap the previous
-- sibling instead of just needing a uniform shift at the end).
local function position_cross_axis(layers, max_layer, feeds_from, label_of, size_of, gap)
  local pos, center = {}, {}
  local function place(id, p)
    pos[id] = p
    center[id] = p + math.floor(size_of(id) / 2)
  end

  do
    local ids = layers[0]
    table.sort(ids, function(a, b)
      return label_of(a) < label_of(b)
    end)
    local cursor = 0
    for _, id in ipairs(ids) do
      place(id, cursor)
      cursor = cursor + size_of(id) + gap
    end
  end

  for l = 1, max_layer do
    local desired = {}
    for _, id in ipairs(layers[l]) do
      local sum, count = 0, 0
      for _, p in ipairs(feeds_from[id]) do
        if center[p] then
          sum, count = sum + center[p], count + 1
        end
      end
      -- must be an integer: the canvas is keyed by integer position, so a
      -- fractional average would silently vanish rather than error.
      desired[id] = count > 0 and math.floor(sum / count + 0.5) or 0
    end

    local ordered = layers[l]
    table.sort(ordered, function(a, b)
      if desired[a] ~= desired[b] then
        return desired[a] < desired[b]
      end
      return label_of(a) < label_of(b)
    end)

    local cursor = -math.huge
    for _, id in ipairs(ordered) do
      local half = math.floor(size_of(id) / 2)
      local p = math.max(desired[id] - half, cursor)
      place(id, p)
      cursor = p + size_of(id) + gap
    end
    layers[l] = ordered
  end

  local min_pos = 0
  for id in pairs(pos) do
    min_pos = math.min(min_pos, pos[id])
  end
  if min_pos < 0 then
    for id in pairs(pos) do
      pos[id], center[id] = pos[id] - min_pos, center[id] - min_pos
    end
  end

  return pos, center
end

local function text_of(node_by_id, id)
  local n = node_by_id[id]
  return n.label .. (n.detail and ("  " .. n.detail) or "")
end

local function new_canvas()
  local canvas = {}
  return canvas,
    function(row, col, ch)
      canvas[row] = canvas[row] or {}
      canvas[row][col] = ch
    end
end

local function flatten_canvas(canvas)
  local max_row, max_col = 0, 0
  for row, cols in pairs(canvas) do
    max_row = math.max(max_row, row)
    for col in pairs(cols) do
      max_col = math.max(max_col, col)
    end
  end
  local lines = {}
  for r = 0, max_row do
    local chars = {}
    for c = 0, max_col do
      chars[c + 1] = (canvas[r] and canvas[r][c]) or " "
    end
    -- trims only trailing space introduced by the fixed grid, never interior gaps
    -- that are load-bearing for the connector art.
    lines[r + 1] = (table.concat(chars):gsub("%s+$", ""))
  end
  return lines
end

-- Sources at the top, the far side of the DAG at the bottom; layers are rows.
local function build_vertical(node_by_id, order, feeds_from, edges, layer, max_layer, layers)
  local function label_of(id)
    return node_by_id[id].label or id
  end
  local width_of = function(id)
    return #text_of(node_by_id, id)
  end

  local box_left, box_center = position_cross_axis(layers, max_layer, feeds_from, label_of, width_of, 3)

  -- row 2*l is layer l's label row; row 2*l-1 is the connector band above it.
  local canvas, put = new_canvas()

  for l = 0, max_layer do
    local row = 2 * l
    for _, id in ipairs(layers[l]) do
      local text = text_of(node_by_id, id)
      local start = box_left[id]
      for i = 1, #text do
        put(row, start + i - 1, text:sub(i, i))
      end
    end
  end

  -- Two unrelated bars can legitimately need the same column in the same band (a
  -- wide sibling can push a node's box further right than its own parent's column,
  -- so its bend's span can overlap a neighboring bend's span even though neither is
  -- logically wrong). Drawing each bend in isolation and overwriting whatever was
  -- there before corrupts one of them; instead, accumulate which of up/down/
  -- left/right each column needs across EVERY bend in this band, then pick one
  -- character per column from the union of flags. Two bars overlapping then renders
  -- as an honest crossing ("┼"), which is normal and legible, rather than silently
  -- losing one bar to the other.
  for l = 1, max_layer do
    local row = 2 * l - 1
    local flags = {}
    local function mark(col, dir)
      flags[col] = flags[col] or {}
      flags[col][dir] = true
    end
    local function mark_span(lo, hi)
      if lo == hi then
        return
      end
      mark(lo, "right")
      mark(hi, "left")
      for col = lo + 1, hi - 1 do
        mark(col, "left")
        mark(col, "right")
      end
    end

    for _, e in ipairs(edges) do
      if node_by_id[e.from] and node_by_id[e.to] then
        if layer[e.from] < l and layer[e.to] > l then
          local col = box_center[e.from]
          mark(col, "up")
          mark(col, "down")
        elseif layer[e.to] == l and layer[e.from] <= l - 1 then
          local from_col, to_col = box_center[e.from], box_center[e.to]
          mark(from_col, "up")
          mark(to_col, "down")
          mark_span(math.min(from_col, to_col), math.max(from_col, to_col))
        end
      end
    end

    for col, f in pairs(flags) do
      put(row, col, bar_char(f.up, f.down, f.left, f.right))
    end
  end

  local lines = flatten_canvas(canvas)
  local line_of, boxes = {}, {}
  for l = 0, max_layer do
    local row = 2 * l + 1 -- 1-indexed
    for _, id in ipairs(layers[l]) do
      line_of[id] = row
      local width = #text_of(node_by_id, id)
      boxes[#boxes + 1] = { id = id, line = row, col_start = box_left[id], col_end = box_left[id] + width - 1 }
    end
  end
  return lines, line_of, boxes
end

-- Sources on the left, the far side of the DAG on the right; layers are columns.
-- The cross axis (siblings within a layer) is now vertical, and every node is
-- exactly one row tall regardless of label length, so cross-axis positioning is
-- simpler than in vertical mode; the layer axis is now horizontal, and text is
-- inherently horizontal, so EACH layer's column width has to fit its widest label.
local function build_horizontal(node_by_id, order, feeds_from, edges, layer, max_layer, layers)
  local CONNECTOR_WIDTH = 4 -- minimum blank columns between one layer's widest label and the next
  local ROW_GAP = 1 -- blank rows between sibling nodes

  local function label_of(id)
    return node_by_id[id].label or id
  end
  local function height_of()
    return 1
  end

  local row_of, row_center = position_cross_axis(layers, max_layer, feeds_from, label_of, height_of, ROW_GAP)

  local layer_width, layer_col = {}, {}
  for l = 0, max_layer do
    local w = 0
    for _, id in ipairs(layers[l]) do
      w = math.max(w, #text_of(node_by_id, id))
    end
    layer_width[l] = w
  end
  layer_col[0] = 0
  for l = 1, max_layer do
    layer_col[l] = layer_col[l - 1] + layer_width[l - 1] + CONNECTOR_WIDTH
  end

  local canvas, put = new_canvas()

  for l = 0, max_layer do
    local col = layer_col[l]
    for _, id in ipairs(layers[l]) do
      local text = text_of(node_by_id, id)
      local r = row_of[id]
      for i = 1, #text do
        put(r, col + i - 1, text:sub(i, i))
      end
    end
  end

  -- Same union-of-flags approach as the vertical renderer (see its comment), with
  -- the layer axis and the sibling axis swapped: "up"/"down" here mean toward an
  -- earlier/later sibling row, "left"/"right" mean toward the source/target layer.
  for l = 1, max_layer do
    local band_start = layer_col[l - 1] + layer_width[l - 1]
    local band_end = layer_col[l] - 1
    if band_end >= band_start then
      local flags = {}
      local function mark(r, c, dir)
        flags[r] = flags[r] or {}
        flags[r][c] = flags[r][c] or {}
        flags[r][c][dir] = true
      end
      local function fill_row(r, c_lo, c_hi)
        for c = c_lo, c_hi do
          mark(r, c, "left")
          mark(r, c, "right")
        end
      end
      local function fill_col(c, r_lo, r_hi)
        if r_lo == r_hi then
          return
        end
        mark(r_lo, c, "down")
        mark(r_hi, c, "up")
        for r = r_lo + 1, r_hi - 1 do
          mark(r, c, "up")
          mark(r, c, "down")
        end
      end

      local bend_col = math.floor((band_start + band_end) / 2)

      for _, e in ipairs(edges) do
        if node_by_id[e.from] and node_by_id[e.to] then
          if layer[e.from] < l and layer[e.to] > l then
            fill_row(row_of[e.from], band_start, band_end)
          elseif layer[e.to] == l and layer[e.from] <= l - 1 then
            local from_row, to_row = row_of[e.from], row_of[e.to]
            if from_row == to_row then
              fill_row(from_row, band_start, band_end)
            else
              fill_row(from_row, band_start, bend_col)
              fill_row(to_row, bend_col, band_end)
              fill_col(bend_col, math.min(from_row, to_row), math.max(from_row, to_row))
            end
          end
        end
      end

      for r, cols in pairs(flags) do
        for c, f in pairs(cols) do
          put(r, c, bar_char(f.up, f.down, f.left, f.right))
        end
      end
    end
  end

  local lines = flatten_canvas(canvas)
  local line_of, boxes = {}, {}
  for l = 0, max_layer do
    local col = layer_col[l]
    for _, id in ipairs(layers[l]) do
      local row = row_of[id] + 1 -- 1-indexed
      line_of[id] = row
      local width = #text_of(node_by_id, id)
      boxes[#boxes + 1] = { id = id, line = row, col_start = col, col_end = col + width - 1 }
    end
  end
  return lines, line_of, boxes
end

-- nodes: array of { id=, label=, detail= (optional) }
-- edges: array of { from=, to= } meaning data flows from -> to ("to" depends on "from")
-- opts.direction: "vertical" (default, top-to-bottom) or "horizontal" (left-to-right)
-- Returns nil if `nodes` is empty.
function M.build(nodes, edges, opts)
  if #nodes == 0 then
    return nil
  end

  local node_by_id, order, feeds_from = build_graph(nodes, edges)
  local layer, max_layer, layers = compute_layers(order, feeds_from)

  local lines, line_of, boxes
  if opts and opts.direction == "horizontal" then
    lines, line_of, boxes = build_horizontal(node_by_id, order, feeds_from, edges, layer, max_layer, layers)
  else
    lines, line_of, boxes = build_vertical(node_by_id, order, feeds_from, edges, layer, max_layer, layers)
  end

  -- line_of[id] is a convenience for "does this node have a line at all" and simple
  -- existence checks; it is NOT enough to answer "what node is under the cursor",
  -- since multiple nodes routinely share one line (every sibling in the same layer,
  -- in either orientation). `boxes` gives each node's exact (line, col_start,
  -- col_end) for real hit-testing.
  return { lines = lines, line_of = line_of, boxes = boxes, layers = layers, layer_of = layer }
end

return M
