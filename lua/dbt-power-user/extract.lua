-- Pure Lua extraction of dbt jinja ref()/source() calls. No editor API is referenced
-- here, so this module runs under bare luajit with zero buffer or window state.

local M = {}

-- Byte positions returned below are 1-based and inclusive, matching Lua string indices,
-- and span from the opening "{{" through the call's closing ")".
local REF_PATTERN = "{{%-?%s*ref%s*(%b())"
local SOURCE_PATTERN = "{{%-?%s*source%s*(%b())"

local function quoted_args(inner)
  local args = {}
  for s in inner:gmatch("['\"]([^'\"]+)['\"]") do
    args[#args + 1] = s
  end
  return args
end

local function scan(text, pattern, build)
  local out = {}
  if type(text) ~= "string" then
    return out
  end
  local init = 1
  while true do
    local s, e, inner = text:find(pattern, init)
    if not s then
      break
    end
    local item = build(quoted_args(inner))
    if item then
      item.start_byte = s
      item.end_byte = e
      out[#out + 1] = item
    end
    init = e + 1
  end
  return out
end

function M.find_refs(text)
  return scan(text, REF_PATTERN, function(args)
    if #args == 1 then
      return { name = args[1] }
    elseif #args >= 2 then
      return { pkg = args[1], name = args[2] }
    end
  end)
end

function M.find_sources(text)
  return scan(text, SOURCE_PATTERN, function(args)
    if #args >= 2 then
      return { source_name = args[1], table_name = args[2] }
    end
  end)
end

local function contains(item, offset)
  return offset >= item.start_byte and offset <= item.end_byte
end

function M.call_under_cursor(text, byte_offset)
  if type(byte_offset) ~= "number" then
    return nil
  end
  for _, ref in ipairs(M.find_refs(text)) do
    if contains(ref, byte_offset) then
      return {
        kind = "ref",
        name = ref.name,
        pkg = ref.pkg,
        start_byte = ref.start_byte,
        end_byte = ref.end_byte,
      }
    end
  end
  for _, source in ipairs(M.find_sources(text)) do
    if contains(source, byte_offset) then
      return {
        kind = "source",
        source_name = source.source_name,
        table_name = source.table_name,
        start_byte = source.start_byte,
        end_byte = source.end_byte,
      }
    end
  end
  return nil
end

function M.completion_context(line_before_cursor)
  if type(line_before_cursor) ~= "string" then
    return nil
  end
  if line_before_cursor:match("ref%s*%(%s*'[^']*'%s*,%s*['\"]?[%w_]*$") then
    return "ref_pkg_name"
  end
  if line_before_cursor:match("source%s*%(%s*'[^']*'%s*,%s*['\"]?[%w_]*$") then
    return "source_table"
  end
  if line_before_cursor:match("ref%s*%(%s*['\"]?[%w_]*$") then
    return "ref_name"
  end
  if line_before_cursor:match("source%s*%(%s*['\"]?[%w_]*$") then
    return "source_name"
  end
  return nil
end

return M
