-- :checkhealth dbt-power-user. Must work before setup() has ever run.

local config = require("dbt-power-user.config")
local manifest = require("dbt-power-user.manifest")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

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

-- vim.keymap.set resolves <leader> when the mapping is created, so maparg only
-- finds a collision if we ask it about the resolved key sequence.
local function resolve_leader(lhs)
  local leader = vim.g.mapleader
  if leader == nil or leader == "" then
    leader = "\\"
  end
  return (lhs:gsub("<[lL]eader>", (tostring(leader):gsub("%%", "%%%%"))))
end

local function check_dbt()
  local cmd = config.options.dbt_cmd or "dbt"
  if vim.fn.executable(cmd) == 1 then
    vim.health.ok(("dbt executable: %s"):format(vim.fn.exepath(cmd) ~= "" and vim.fn.exepath(cmd) or cmd))
  else
    vim.health.error(("`%s` is not executable"):format(cmd), {
      "Install dbt-core, or point opts.dbt_cmd at its absolute path",
    })
  end
end

local function check_project()
  local root = config.options.project_dir or project.find_root()
  if not root then
    vim.health.warn("no dbt project found under cwd", {
      "Open a file inside a dbt project, or set opts.project_dir",
    })
    return nil
  end

  local parsed = project.parse_dbt_project_yml(root)
  vim.health.ok(("dbt project: %s (%s)"):format(parsed and parsed.name or "unnamed", root))
  return root, parsed
end

local function check_artifacts(root)
  local target_dir = project.target_dir(root)

  if manifest.load(root) then
    vim.health.ok(("manifest: %s"):format(util.path_join(target_dir, "manifest.json")))
  else
    vim.health.warn("no usable target/manifest.json", {
      "run `dbt parse` to generate a manifest",
    })
  end

  if manifest.load_catalog(root) then
    vim.health.ok(("catalog: %s"):format(util.path_join(target_dir, "catalog.json")))
  else
    vim.health.info("no target/catalog.json — column diagnostics and hover types stay quiet until `dbt docs generate` has run")
  end
end

local function check_profiles(root, parsed)
  local path = profiles_file(root)
  if not path then
    vim.health.warn("no profiles.yml found", {
      "Create ~/.dbt/profiles.yml, or set opts.profiles_dir",
    })
    return
  end

  local profile = parsed and parsed.profile
  vim.health.ok(("profiles.yml: %s%s"):format(path, profile and (" (profile `" .. profile .. "`)") or ""))
end

local function check_prefix()
  local prefix = config.options.prefix or "<leader>D"
  local resolved = resolve_leader(prefix)
  local existing = vim.fn.maparg(resolved, "n")
  if existing ~= "" then
    vim.health.warn(("prefix %s is already mapped to `%s`"):format(prefix, existing), {
      "Set opts.prefix to something free, e.g. `<leader>M`",
    })
  else
    vim.health.ok(("prefix %s is free"):format(prefix))
  end
end

function M.check()
  vim.health.start("dbt-power-user")

  check_dbt()

  local root, parsed = check_project()
  if root then
    check_artifacts(root)
  end
  check_profiles(root, parsed)

  check_prefix()
end

return M
