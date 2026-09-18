-- Single-string project/target indicator for lualine (wiring is the user's job).

local config = require("dbt-power-user.config")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

local ICON = "󰆼"

-- Cached because lualine calls this on every redraw and both lookups hit the disk.
local cache = {}

local function profiles_file(root_dir)
  local candidates = {}
  if config.options.profiles_dir and config.options.profiles_dir ~= "" then
    candidates[#candidates + 1] = config.options.profiles_dir
  end
  if root_dir and root_dir ~= "" then
    candidates[#candidates + 1] = root_dir
  end
  if vim.env.DBT_PROFILES_DIR and vim.env.DBT_PROFILES_DIR ~= "" then
    candidates[#candidates + 1] = vim.env.DBT_PROFILES_DIR
  end
  candidates[#candidates + 1] = vim.fn.expand("~/.dbt")

  for _, dir in ipairs(candidates) do
    local path = util.path_join(dir, "profiles.yml")
    if vim.uv.fs_stat(path) then
      return path
    end
  end
  return nil
end

-- Best-effort read of the profile's own default target: find the top-level block
-- named by dbt_project.yml's `profile:`, then its indented `target:` key.
local function profile_target(root_dir, profile_name)
  if not profile_name then
    return nil
  end
  local path = profiles_file(root_dir)
  local content = path and util.read_file(path)
  if not content then
    return nil
  end

  local inside = false
  for line in content:gmatch("[^\r\n]+") do
    local top_level = line:match("^([%w_%-]+):")
    if top_level then
      inside = top_level == profile_name
    elseif inside then
      local target = line:match("^%s+target:%s*\"?([%w_%-]+)\"?")
      if target then
        return target
      end
    end
  end
  return nil
end

function M.status()
  local root = project.get_root(0)
  if not root then
    return ""
  end

  local key = root .. "\0" .. tostring(config.options.target)
  if cache[key] then
    return cache[key]
  end

  local parsed = project.parse_dbt_project_yml(root)
  local name = (parsed and parsed.name) or vim.fs.basename(root)
  local target = config.options.target or profile_target(root, parsed and parsed.profile)

  local status = target and (name .. " " .. ICON .. " " .. target) or name
  cache[key] = status
  return status
end

function M.invalidate()
  cache = {}
end

return M
