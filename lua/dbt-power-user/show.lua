-- Query preview: runs `dbt show` and renders the returned rows as an aligned table.

local config = require("dbt-power-user.config")
local job = require("dbt-power-user.job")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

local NULL = "NULL"

local function decode_payload(stdout)
  if type(stdout) ~= "string" or stdout == "" then
    return nil
  end

  local ok, data = util.json_decode(stdout)
  if ok and type(data) == "table" then
    return data
  end

  local first = stdout:find("{", 1, true)
  local last = stdout:find("}[^}]*$")
  if not first or not last or last < first then
    return nil
  end
  ok, data = util.json_decode(stdout:sub(first, last))
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

local function is_null(value)
  return value == nil or value == vim.NIL
end

-- vim.json.decode throws away object key order, but dbt emits the columns in the
-- query's own order, so recover it from the raw payload. dbt pretty-prints with
-- indent=2 and JSON escapes every newline inside a value, so one key per line holds.
local function column_order(raw, row)
  local names, seen = {}, {}
  local started = false

  for _, line in ipairs(vim.split(raw or "", "\n", { plain = true })) do
    if not started then
      -- the first indented bare "{" is the opening brace of the first row object
      started = line:match("^%s+{%s*$") ~= nil
    else
      local key = line:match('^%s*"(.-)"%s*:')
      if key then
        if not seen[key] then
          seen[key] = true
          names[#names + 1] = key
        end
      elseif line:match("^%s*[}%]]") then
        break
      end
    end
  end

  local extra = {}
  for key in pairs(row) do
    if not seen[key] then
      extra[#extra + 1] = key
    end
  end
  table.sort(extra)
  vim.list_extend(names, extra)

  local columns = {}
  for _, key in ipairs(names) do
    if row[key] ~= nil then
      columns[#columns + 1] = key
    end
  end
  return columns
end

-- agate's to_json turns every Decimal into a float, so whole numbers arrive as 1.0.
-- Render them as integers, but only when the whole column is integral.
local function integral_column(rows, key)
  local any = false
  for _, row in ipairs(rows) do
    local value = row[key]
    if not is_null(value) then
      if type(value) ~= "number" or value ~= math.floor(value) or math.abs(value) >= 2 ^ 53 then
        return false
      end
      any = true
    end
  end
  return any
end

local function cell(value, integral)
  if is_null(value) then
    return NULL
  end
  if type(value) == "boolean" then
    return tostring(value)
  end
  if type(value) == "number" then
    return integral and string.format("%.0f", value) or string.format("%.14g", value)
  end
  return tostring(value)
end

-- nvim_buf_set_lines rejects a string containing a newline, and a tab would break the
-- column alignment, so control characters are escaped for display only. The CSV and
-- JSON yanks keep the value as it came back.
local function display(value, integral)
  local text = cell(value, integral)
  text = text:gsub("\r\n", "\\n"):gsub("[\n\r]", "\\n"):gsub("\t", "    ")
  return (text:gsub("%c", " "))
end

local function render(columns, rows, integral)
  local widths, body = {}, {}
  for i, key in ipairs(columns) do
    widths[i] = vim.fn.strdisplaywidth(key)
  end

  for r, row in ipairs(rows) do
    body[r] = {}
    for i, key in ipairs(columns) do
      local text = display(row[key], integral[i])
      body[r][i] = text
      widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(text))
    end
  end

  local function line(values)
    local parts = {}
    for i, text in ipairs(values) do
      parts[i] = text .. string.rep(" ", widths[i] - vim.fn.strdisplaywidth(text))
    end
    return "| " .. table.concat(parts, " | ") .. " |"
  end

  local rule = {}
  for i in ipairs(columns) do
    rule[i] = string.rep("-", widths[i])
  end

  local out = { line(columns), "|-" .. table.concat(rule, "-|-") .. "-|" }
  for _, values in ipairs(body) do
    out[#out + 1] = line(values)
  end
  out[#out + 1] = ""
  out[#out + 1] = ("-- %d row(s). yc = yank CSV, yj = yank JSON, q = close."):format(#rows)
  return out
end

local function csv(columns, rows, integral)
  local function field(text)
    if text:find('[,"\r\n]') then
      return '"' .. text:gsub('"', '""') .. '"'
    end
    return text
  end

  local lines = {}
  local header = {}
  for i, key in ipairs(columns) do
    header[i] = field(key)
  end
  lines[1] = table.concat(header, ",")

  for _, row in ipairs(rows) do
    local values = {}
    for i, key in ipairs(columns) do
      local value = row[key]
      values[i] = is_null(value) and "" or field(cell(value, integral[i]))
    end
    lines[#lines + 1] = table.concat(values, ",")
  end
  return table.concat(lines, "\n")
end

local function open_results(title, lines, yanks)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, title)

  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.max(3, math.min(#lines, math.floor(vim.o.lines * 0.4))))

  local function yank(text, label)
    vim.fn.setreg("+", text)
    vim.fn.setreg('"', text)
    util.notify("yanked results as " .. label)
  end

  vim.keymap.set("n", "yc", function()
    yank(yanks.csv, "CSV")
  end, { buffer = buf, desc = "dbt: yank results as CSV" })

  vim.keymap.set("n", "yj", function()
    yank(yanks.json, "JSON")
  end, { buffer = buf, desc = "dbt: yank results as JSON" })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf, desc = "dbt: close results" })

  return buf
end

local function show(argv_head, title)
  local argv = vim.list_extend({}, argv_head)
  vim.list_extend(argv, {
    "--output",
    "json",
    "--quiet",
    "--limit",
    tostring(config.options.query_limit),
    "--no-use-colors",
  })

  return job.run_dbt(argv, {
    on_exit = function(res)
      if res.code ~= 0 then
        return util.notify(util.job_failure_message("show", res), vim.log.levels.ERROR)
      end

      local data = decode_payload(res.stdout)
      if not data then
        return util.notify("could not parse dbt output", vim.log.levels.ERROR)
      end

      local rows = type(data.show) == "table" and data.show or nil
      if not rows then
        return util.notify("dbt returned no result set", vim.log.levels.WARN)
      end
      if #rows == 0 then
        return util.notify("query returned no rows")
      end

      local columns = column_order(res.stdout, rows[1])
      if #columns == 0 then
        return util.notify("query returned no columns", vim.log.levels.WARN)
      end

      local integral = {}
      for i, key in ipairs(columns) do
        integral[i] = integral_column(rows, key)
      end

      open_results(title, render(columns, rows, integral), {
        csv = csv(columns, rows, integral),
        json = vim.json.encode(rows),
      })
    end,
  })
end

-- Linewise, so a selection that clips mid-statement still runs as written.
function M.visual_selection()
  local first, last = vim.fn.line("'<"), vim.fn.line("'>")
  if first == 0 or last == 0 or last < first then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

local function resolve_sql(opts)
  if type(opts.sql) == "string" and opts.sql ~= "" then
    return opts.sql
  end

  if opts.range then
    if type(opts.range) == "table" then
      local first = opts.range.start_line or opts.range[1]
      local last = opts.range.end_line or opts.range[2]
      if first and last and first > 0 and last >= first then
        return table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n")
      end
    end
    local selection = M.visual_selection()
    if selection then
      return selection
    end
  end

  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

function M.preview_query(opts)
  opts = opts or {}
  local sql = resolve_sql(opts)
  if not sql or sql:match("^%s*$") then
    util.notify("nothing to preview", vim.log.levels.WARN)
    return nil
  end
  return show({ "show", "--inline", sql }, "dbt show [inline]")
end

function M.preview_model(model_name)
  if not model_name or model_name == "" then
    local root = project.get_root(0)
    model_name = root and project.model_name_from_path(vim.api.nvim_buf_get_name(0), root)
  end
  if not model_name or model_name == "" then
    util.notify("current buffer is not a dbt model", vim.log.levels.WARN)
    return nil
  end
  return show({ "show", "--select", model_name }, "dbt show [" .. model_name .. "]")
end

return M
