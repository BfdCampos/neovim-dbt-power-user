-- dbt node-selector expansion. Pure string handling, no editor state.

local M = {}

-- "%" is this plugin's own shorthand for the current model, not a dbt selector
-- operator, so it is replaced as a literal character wherever it appears:
-- "%+" -> "customers+", "+%+" -> "+customers+", "%,@other" -> "customers,@other".
function M.expand(selector_str, current_model_name)
  if type(selector_str) ~= "string" then
    return nil
  end
  if type(current_model_name) ~= "string" or current_model_name == "" then
    return selector_str
  end

  local parts, init = {}, 1
  while true do
    local found = selector_str:find("%", init, true)
    if not found then
      parts[#parts + 1] = selector_str:sub(init)
      break
    end
    parts[#parts + 1] = selector_str:sub(init, found - 1)
    init = found + 1
  end

  return table.concat(parts, current_model_name)
end

return M
