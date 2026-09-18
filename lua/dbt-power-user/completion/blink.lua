-- blink.cmp source completing dbt ref() and source() arguments.

local extract = require("dbt-power-user.extract")
local manifest = require("dbt-power-user.manifest")
local project = require("dbt-power-user.project")

-- LSP CompletionItemKind numbers; used directly so this module loads without blink.
local KIND = { module = 9, struct = 22, folder = 19 }

local REF_TYPES = { model = true, seed = true, snapshot = true }

local Source = {}

function Source.new(opts, config)
  local self = setmetatable({}, { __index = Source })
  self.opts = opts or {}
  self.config = config or {}
  return self
end

function Source:enabled()
  return vim.bo.filetype == "sql"
end

function Source:get_trigger_characters()
  return { "'", '"', "(" }
end

local function root_for(ctx)
  local bufnr = ctx and ctx.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return project.get_root(bufnr)
  end
  return project.find_root()
end

local function item(label, kind, detail, documentation)
  return {
    label = label,
    kind = kind,
    detail = detail,
    insertText = label,
    insertTextFormat = 1,
    documentation = documentation and { kind = "markdown", value = documentation } or nil,
  }
end

local function ref_items(root_dir, pkg)
  local items = {}
  for _, node in pairs(manifest.graph(root_dir).nodes) do
    if REF_TYPES[node.resource_type] and node.name and (not pkg or node.package_name == pkg) then
      local path = type(node.original_file_path) == "string" and ("`" .. node.original_file_path .. "`") or nil
      items[#items + 1] = item(node.name, KIND.module, node.resource_type, path)
    end
  end
  return items
end

local function source_name_items(root_dir)
  local items = {}
  for source_name, tables in pairs(manifest.sources(root_dir)) do
    local count = 0
    for _ in pairs(tables) do
      count = count + 1
    end
    items[#items + 1] = item(source_name, KIND.folder, count .. " tables")
  end
  return items
end

local function source_table_items(root_dir, source_name)
  local items = {}
  local tables = source_name and manifest.sources(root_dir)[source_name]
  for table_name in pairs(tables or {}) do
    items[#items + 1] = item(table_name, KIND.struct, source_name)
  end
  return items
end

-- First quoted argument of the call being completed, i.e. the package for a two-arg
-- ref() or the source name for a source().
local function first_argument(before, fn)
  return before:match(fn .. "%s*%(%s*['\"]([^'\"]*)['\"]%s*,")
end

local function completions_for(root_dir, before)
  local context = extract.completion_context(before)
  if not context or not root_dir then
    return {}
  end
  if context == "ref_name" then
    return ref_items(root_dir, nil)
  elseif context == "ref_pkg_name" then
    return ref_items(root_dir, first_argument(before, "ref"))
  elseif context == "source_name" then
    return source_name_items(root_dir)
  elseif context == "source_table" then
    return source_table_items(root_dir, first_argument(before, "source"))
  end
  return {}
end

function Source:get_completions(ctx, callback)
  local before = ""
  if ctx and type(ctx.line) == "string" then
    local col = ctx.cursor and ctx.cursor[2] or #ctx.line
    before = ctx.line:sub(1, col)
  end

  local ok, items = pcall(completions_for, root_for(ctx), before)
  callback({
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = ok and items or {},
  })

  return function() end
end

return Source
