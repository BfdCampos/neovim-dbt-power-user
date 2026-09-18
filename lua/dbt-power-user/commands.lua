-- :Dbt* user commands and the keymap-facing convenience wrappers.

local config = require("dbt-power-user.config")
local job = require("dbt-power-user.job")
local manifest = require("dbt-power-user.manifest")
local project = require("dbt-power-user.project")
local quickfix = require("dbt-power-user.quickfix")
local selector = require("dbt-power-user.selector")
local util = require("dbt-power-user.util")

local M = {}

local DIRECTIONS = {
  current = "%",
  upstream = "+%",
  downstream = "%+",
  both = "+%+",
}

-- Bare verbs, not "dbt run"/"dbt compile" -- util.notify already prefixes every
-- message with "[dbt] ", so a name starting with "dbt" reads as a stutter.
local SPECS = {
  DbtRun = { name = "run", argv = { "run" }, select = true, defer = true, quickfix = true },
  DbtBuild = { name = "build", argv = { "build" }, select = true, defer = true, quickfix = true },
  DbtTest = { name = "test", argv = { "test" }, select = true, quickfix = true },
  DbtCompile = { name = "compile", argv = { "compile" }, select = true, defer = true },
  DbtSeed = { name = "seed", argv = { "seed" }, select = true },
  DbtDeps = { name = "deps", argv = { "deps" } },
  DbtClean = { name = "clean", argv = { "clean" } },
  DbtParse = { name = "parse", argv = { "parse" } },
  DbtDocsGenerate = { name = "docs generate", argv = { "docs", "generate" } },
}

-- defer.lua is optional; a missing module just means no --defer/--state arguments.
local function defer_args()
  local ok, defer = pcall(require, "dbt-power-user.defer")
  if not ok or type(defer.extra_args) ~= "function" then
    return {}
  end
  local args = defer.extra_args()
  return type(args) == "table" and args or {}
end

local function resolve_root()
  return config.options.project_dir or project.get_root(0)
end

local function resolve_selector(raw, root)
  local value = (type(raw) == "string" and raw ~= "" and raw) or "%"
  if not value:find("%", 1, true) then
    return value
  end

  local name = project.model_name_from_path(vim.api.nvim_buf_get_name(0), root)
  if not name then
    util.notify("current buffer is not a dbt model, pass an explicit selector", vim.log.levels.WARN)
    return nil
  end
  return selector.expand(value, name)
end

local function execute(spec, raw_selector)
  local root = resolve_root()
  if not root then
    util.notify("no dbt project found, could not locate dbt_project.yml", vim.log.levels.WARN)
    return
  end

  local argv = vim.list_extend({}, spec.argv)
  if spec.select then
    local expanded = resolve_selector(raw_selector, root)
    if not expanded then
      return
    end
    vim.list_extend(argv, { "--select", expanded })
  end
  if spec.defer then
    vim.list_extend(argv, defer_args())
  end

  return job.run_dbt(argv, {
    on_exit = function(res)
      manifest.invalidate(root)
      local failures = spec.quickfix and quickfix.populate_from_run_results(root) or nil
      if res.code == 0 then
        local suffix = ""
        if failures and #failures > 0 then
          suffix = " with " .. #failures .. " failure(s)"
        end
        util.notify(spec.name .. " finished" .. suffix)
      else
        util.notify(util.job_failure_message(spec.name, res), vim.log.levels.ERROR)
      end
    end,
  })
end

function M.setup()
  for command, spec in pairs(SPECS) do
    vim.api.nvim_create_user_command(command, function(args)
      execute(spec, args.args)
    end, { nargs = spec.select and "?" or 0, desc = spec.name })
  end
end

local function direction_selector(direction)
  if direction == nil or direction == "" then
    return "%"
  end
  return DIRECTIONS[direction] or direction
end

function M.run_model(direction)
  return execute(SPECS.DbtRun, direction_selector(direction))
end

function M.build_model(direction)
  return execute(SPECS.DbtBuild, direction_selector(direction))
end

function M.test_model()
  return execute(SPECS.DbtTest, "%")
end

function M.compile_model(direction)
  return execute(SPECS.DbtCompile, direction_selector(direction))
end

return M
