-- Defer-to-production toggle. commands.lua appends extra_args() to every run/build/compile.

local config = require("dbt-power-user.config")
local util = require("dbt-power-user.util")

local M = {}

M.enabled = false

function M.toggle()
  M.enabled = not M.enabled

  if M.enabled and not config.options.defer_state_path then
    util.notify(
      "defer on, but opts.defer_state_path is unset so --defer will be skipped",
      vim.log.levels.WARN
    )
    return M.enabled
  end

  util.notify("defer " .. (M.enabled and "on" or "off"))
  return M.enabled
end

function M.extra_args()
  local state = config.options.defer_state_path
  if not M.enabled or not state or state == "" then
    return {}
  end
  return { "--defer", "--state", state }
end

return M
