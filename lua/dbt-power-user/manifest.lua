-- dbt artifact loading (manifest/catalog/run_results) and the filtered DAG projection.

local util = require("dbt-power-user.util")
local project = require("dbt-power-user.project")

local M = {}

-- Resource types that belong in the lineage projection. Tests, unit tests, semantic
-- models, metrics and saved queries all appear in parent_map/child_map and would
-- otherwise show up as phantom parents and children of every model.
local GRAPH_RESOURCE_TYPES = {
  model = true,
  seed = true,
  snapshot = true,
  source = true,
}

local caches = {
  manifest = {},
  catalog = {},
  run_results = {},
  graph = {},
  sources = {},
  target_dir = {},
}

local watchers = {}

-- JSON null decodes to vim.NIL, which is truthy userdata, so every field read from an
-- artifact goes through one of these two guards.
local function as_string(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function as_table(value)
  if type(value) == "table" then
    return value
  end
  return nil
end

local function target_dir(root_dir)
  local cached = caches.target_dir[root_dir]
  if cached then
    return cached
  end
  local dir = project.target_dir(root_dir)
  caches.target_dir[root_dir] = dir
  return dir
end

local function artifact_path(root_dir, filename)
  if not root_dir or root_dir == "" then
    return nil
  end
  return util.path_join(target_dir(root_dir), filename)
end

local function load_artifact(cache, root_dir, filename)
  local path = artifact_path(root_dir, filename)
  if not path then
    return nil
  end

  local mtime = util.file_mtime(path)
  if not mtime then
    cache[root_dir] = nil
    return nil
  end

  local cached = cache[root_dir]
  if cached and cached.mtime == mtime then
    return cached.data
  end

  -- dbt replaces the artifact non-atomically, so a read can land mid-write and see a
  -- truncated file. Stale-but-valid beats nothing: fall back to the last good cache
  -- entry (if any) rather than surfacing a transient decode failure to callers.
  -- (NOTE: `content and util.json_decode(content)` would look equivalent here but
  -- isn't -- Lua's `and` adjusts a multi-return call to ONE value, silently dropping
  -- `data` every time. Keep these as two statements.)
  local content = util.read_file(path)
  if not content then
    return cached and cached.data or nil
  end
  local ok, data = util.json_decode(content)
  if not ok or type(data) ~= "table" then
    return cached and cached.data or nil
  end

  cache[root_dir] = { mtime = mtime, data = data }
  return data
end

function M.load(root_dir)
  return load_artifact(caches.manifest, root_dir, "manifest.json")
end

-- A node missing from the catalog means "not built yet", which is normal, not an error.
function M.load_catalog(root_dir)
  return load_artifact(caches.catalog, root_dir, "catalog.json")
end

function M.load_run_results(root_dir)
  return load_artifact(caches.run_results, root_dir, "run_results.json")
end

function M.invalidate(root_dir)
  for _, cache in pairs(caches) do
    if root_dir then
      cache[root_dir] = nil
    else
      for key in pairs(cache) do
        cache[key] = nil
      end
    end
  end
end

function M.watch(root_dir, on_change)
  if not root_dir or root_dir == "" then
    return nil
  end

  local existing = watchers[root_dir]
  if existing then
    if on_change then
      existing.callbacks[#existing.callbacks + 1] = on_change
    end
    return existing.handle
  end

  local path = artifact_path(root_dir, "manifest.json")
  local handle = path and vim.uv.new_fs_event()
  if not handle then
    return nil
  end

  local entry = { handle = handle, callbacks = {}, timer = vim.uv.new_timer() }
  if on_change then
    entry.callbacks[1] = on_change
  end
  watchers[root_dir] = entry

  -- A single dbt invocation can touch manifest.json more than once in quick
  -- succession (a partial-parse write followed by a full rewrite once compiled), and
  -- each write can itself fire more than one raw fs_event on macOS. Re-arming has to
  -- happen immediately on every raw event (dbt replaces the file rather than editing
  -- it in place, which drops an inode-level watch), but the user-facing side --
  -- cache invalidation and the on_change callbacks -- is debounced behind a timer so
  -- a burst of writes collapses into exactly one refresh/notification.
  local function arm()
    handle:start(path, {}, function(err)
      if err then
        return
      end
      handle:stop()
      arm()

      entry.timer:stop()
      entry.timer:start(200, 0, function()
        util.schedule(function()
          M.invalidate(root_dir)
          for _, callback in ipairs(entry.callbacks) do
            pcall(callback, root_dir)
          end
        end)
      end)
    end)
  end
  arm()

  return handle
end

local function project_node(unique_id, node)
  local config = as_table(node.config) or {}
  return {
    unique_id = unique_id,
    name = as_string(node.name),
    resource_type = as_string(node.resource_type),
    path = as_string(node.path),
    original_file_path = as_string(node.original_file_path),
    package_name = as_string(node.package_name),
    database = as_string(node.database),
    schema = as_string(node.schema),
    materialized = as_string(config.materialized) or "view",
    source_name = as_string(node.source_name),
  }
end

local function collect_edges(map, buckets, nodes)
  for unique_id, related in pairs(map) do
    local bucket = buckets[unique_id]
    if bucket and type(related) == "table" then
      for _, other in ipairs(related) do
        if nodes[other] then
          bucket[#bucket + 1] = other
        end
      end
    end
  end
end

local function build_graph(manifest)
  local nodes, raw = {}, {}

  local groups = {}
  if as_table(manifest.nodes) then
    groups[#groups + 1] = manifest.nodes
  end
  if as_table(manifest.sources) then
    groups[#groups + 1] = manifest.sources
  end
  for _, group in ipairs(groups) do
    for unique_id, node in pairs(group) do
      if type(node) == "table" and GRAPH_RESOURCE_TYPES[node.resource_type] then
        nodes[unique_id] = project_node(unique_id, node)
        raw[unique_id] = node
      end
    end
  end

  local parents, children = {}, {}
  for unique_id in pairs(nodes) do
    parents[unique_id] = {}
    children[unique_id] = {}
  end

  local parent_map = as_table(manifest.parent_map)
  if parent_map then
    collect_edges(parent_map, parents, nodes)
  else
    for unique_id, node in pairs(raw) do
      local depends_on = as_table(node.depends_on)
      local depends = depends_on and as_table(depends_on.nodes)
      if depends then
        for _, other in ipairs(depends) do
          if nodes[other] then
            table.insert(parents[unique_id], other)
          end
        end
      end
    end
  end

  local child_map = as_table(manifest.child_map)
  if child_map then
    collect_edges(child_map, children, nodes)
  else
    for unique_id, list in pairs(parents) do
      for _, parent in ipairs(list) do
        table.insert(children[parent], unique_id)
      end
    end
  end

  for _, list in pairs(parents) do
    table.sort(list)
  end
  for _, list in pairs(children) do
    table.sort(list)
  end

  return { nodes = nodes, parents = parents, children = children }
end

function M.graph(root_dir)
  local manifest = M.load(root_dir)
  if not manifest then
    return { nodes = {}, parents = {}, children = {} }
  end

  local cached = caches.graph[root_dir]
  if cached and cached.manifest == manifest then
    return cached.graph
  end

  local graph = build_graph(manifest)
  caches.graph[root_dir] = { manifest = manifest, graph = graph }
  return graph
end

-- Model names are unique within a package but not across them, so rank the root
-- project's own nodes first and fall back to unique_id order for stability.
local function pick(candidates, preferred_package)
  if #candidates == 0 then
    return nil
  end
  table.sort(candidates, function(a, b)
    local a_preferred = a.package_name == preferred_package
    local b_preferred = b.package_name == preferred_package
    if a_preferred ~= b_preferred then
      return a_preferred
    end
    return a.unique_id < b.unique_id
  end)
  return candidates[1]
end

local function root_package(root_dir)
  local manifest = M.load(root_dir)
  local metadata = manifest and as_table(manifest.metadata)
  return metadata and as_string(metadata.project_name)
end

function M.find_node_by_name(root_dir, name, resource_type_filter)
  if not name or name == "" then
    return nil
  end

  local graph = M.graph(root_dir)
  local candidates = {}
  for _, node in pairs(graph.nodes) do
    if not resource_type_filter or node.resource_type == resource_type_filter then
      local qualified = node.source_name and (node.source_name .. "." .. (node.name or ""))
      if node.name == name or qualified == name then
        candidates[#candidates + 1] = node
      end
    end
  end

  local best = pick(candidates, root_package(root_dir))
  return best and best.unique_id or nil
end

local function project_relative(root_dir, path)
  path = (path:gsub("^%./", ""))
  if path:sub(1, 1) ~= "/" then
    return path
  end

  local absolute = (vim.fn.fnamemodify(path, ":p"):gsub("/+$", ""))
  local root = (vim.fn.fnamemodify(root_dir, ":p"):gsub("/+$", ""))
  if absolute:sub(1, #root + 1) == root .. "/" then
    return absolute:sub(#root + 2)
  end
  return nil
end

function M.find_node_by_path(root_dir, abs_or_relative_path)
  if not root_dir or root_dir == "" or not abs_or_relative_path or abs_or_relative_path == "" then
    return nil
  end

  local relative = project_relative(root_dir, abs_or_relative_path)
  if not relative then
    return nil
  end

  local graph = M.graph(root_dir)
  local preferred = root_package(root_dir)

  for _, field in ipairs({ "original_file_path", "path" }) do
    local candidates = {}
    for _, node in pairs(graph.nodes) do
      if node[field] == relative then
        candidates[#candidates + 1] = node
      end
    end
    local best = pick(candidates, preferred)
    if best then
      return best.unique_id
    end
  end

  return nil
end

-- candidate is either "pkg.name" or a bare "name". A package-qualified call resolves
-- against that package first; a self-prefixed call still has to find the bare
-- current-project macro, so fall through to a name lookup either way.
function M.macro_lookup(root_dir, candidate)
  if not candidate or candidate == "" then
    return nil
  end

  local manifest = M.load(root_dir)
  local macros = manifest and as_table(manifest.macros)
  if not macros then
    return nil
  end

  local name = candidate
  local pkg, suffix = candidate:match("^([%w_]+)%.([%w_]+)$")
  if pkg then
    local exact = macros["macro." .. pkg .. "." .. suffix]
    if as_table(exact) then
      return exact
    end
    name = suffix
  end

  local candidates = {}
  for unique_id, macro in pairs(macros) do
    if type(macro) == "table" and macro.name == name then
      candidates[#candidates + 1] = {
        unique_id = unique_id,
        package_name = as_string(macro.package_name),
        macro = macro,
      }
    end
  end

  local best = pick(candidates, root_package(root_dir))
  return best and best.macro or nil
end

function M.sources(root_dir)
  local manifest = M.load(root_dir)
  if not manifest then
    return {}
  end

  local cached = caches.sources[root_dir]
  if cached and cached.manifest == manifest then
    return cached.sources
  end

  local sources = {}
  for unique_id, node in pairs(as_table(manifest.sources) or {}) do
    if type(node) == "table" then
      local source_name = as_string(node.source_name)
      local table_name = as_string(node.name)
      if source_name and table_name then
        sources[source_name] = sources[source_name] or {}
        sources[source_name][table_name] = unique_id
      end
    end
  end

  caches.sources[root_dir] = { manifest = manifest, sources = sources }
  return sources
end

return M
