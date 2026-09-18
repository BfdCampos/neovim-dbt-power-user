-- Shared helpers. No dependencies on any other module in this plugin.

local M = {}

function M.notify(msg, level)
  vim.notify("[dbt] " .. tostring(msg), level or vim.log.levels.INFO)
end

-- vim.system callbacks run in a fast-event context where nvim API calls are
-- forbidden, so every callback that touches the editor goes through here.
function M.schedule(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

function M.json_decode(str)
  return pcall(vim.json.decode, str)
end

function M.read_file(path)
  local fd, open_err = io.open(path, "r")
  if not fd then
    return nil, open_err or ("could not open " .. tostring(path))
  end
  local content = fd:read("*a")
  fd:close()
  if not content then
    return nil, "could not read " .. tostring(path)
  end
  return content
end

function M.file_mtime(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or not stat.mtime then
    return nil
  end
  return stat.mtime.sec
end

-- dbt's own errors (bad profile, jinja error, connection failure) usually print to
-- stdout via its logging framework, not stderr, and --quiet still lets ERROR-level
-- lines through -- so a failure with empty stderr very often still has the real
-- detail sitting in stdout. Try stderr first, then stdout, and return the LAST
-- non-empty line of whichever has content (the summary line dbt prints last),
-- or nil if there is genuinely nothing to show.
function M.job_failure_detail(res)
  for _, stream in ipairs({ res.stderr, res.stdout }) do
    if type(stream) == "string" and stream ~= "" then
      local tail
      for line in stream:gmatch("[^\r\n]+") do
        if line:match("%S") then
          tail = line
        end
      end
      if tail then
        return tail
      end
    end
  end
  return nil
end

-- Builds a consistent "<label> failed (exit N)[: detail]" message. `label` should be
-- a bare verb ("compile", "run", "show") -- M.notify already prefixes "[dbt] ", so a
-- label starting with "dbt" reads as a stutter ("[dbt] dbt compile failed").
function M.job_failure_message(label, res)
  local message = label .. " failed (exit " .. tostring(res.code) .. ")"
  local detail = M.job_failure_detail(res)
  if detail then
    message = message .. ": " .. detail
  end
  return message
end

function M.path_join(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local part = select(i, ...)
    if part ~= nil and part ~= "" then
      parts[#parts + 1] = tostring(part)
    end
  end
  local joined = table.concat(parts, "/")
  return (joined:gsub("//+", "/"))
end

return M
