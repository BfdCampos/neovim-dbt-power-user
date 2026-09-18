-- Async process execution via vim.system. Every callback vim.system hands back runs in
-- a fast-event context, so all of them are re-entered on the main loop via util.schedule.

local config = require("dbt-power-user.config")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

local function stream(handler, chunks)
  return function(err, data)
    if err or not data then
      return
    end
    chunks[#chunks + 1] = data
    if handler then
      for line in data:gmatch("[^\n]+") do
        util.schedule(function()
          handler(line)
        end)
      end
    end
  end
end

function M.run(argv, opts)
  opts = opts or {}
  local stdout_chunks, stderr_chunks = {}, {}

  local ok, handle = pcall(vim.system, argv, {
    text = true,
    cwd = opts.cwd,
    env = opts.env,
    stdout = stream(opts.on_stdout, stdout_chunks),
    stderr = stream(opts.on_stderr, stderr_chunks),
  }, function(res)
    -- Streaming handlers leave res.stdout/res.stderr empty, so the collected chunks go
    -- back on the result for callers that want the whole output (compile, show).
    res.stdout = res.stdout or table.concat(stdout_chunks)
    res.stderr = res.stderr or table.concat(stderr_chunks)
    util.schedule(function()
      if opts.on_exit then
        opts.on_exit(res)
      end
    end)
  end)

  if not ok then
    util.notify(handle, vim.log.levels.ERROR)
    return nil
  end
  return handle
end

function M.run_dbt(subcmd_argv, opts)
  local options = config.options
  local root = options.project_dir or project.find_root()

  local argv = { options.dbt_cmd or "dbt" }
  vim.list_extend(argv, subcmd_argv or {})
  if options.no_version_check then
    argv[#argv + 1] = "--no-version-check"
  end
  if root then
    vim.list_extend(argv, { "--project-dir", root })
  end
  if options.profiles_dir then
    vim.list_extend(argv, { "--profiles-dir", options.profiles_dir })
  end
  if options.target then
    vim.list_extend(argv, { "--target", options.target })
  end

  return M.run(argv, vim.tbl_extend("keep", opts or {}, { cwd = root }))
end

return M
