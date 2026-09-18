-- dbt project root detection and dbt_project.yml parsing.

local util = require("dbt-power-user.util")

local M = {}

local root_cache = {}

local function strip_trailing_slash(path)
  return (path:gsub("(.)/+$", "%1"))
end

local function absolute(path)
  return strip_trailing_slash(vim.fn.fnamemodify(path, ":p"))
end

local function containing_dir(path)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    return path
  end
  return vim.fs.dirname(path)
end

function M.find_root(start_path)
  local start = start_path
  if not start or start == "" then
    local bufdir = vim.fn.expand("%:p:h")
    start = (bufdir ~= "" and bufdir) or vim.uv.cwd()
  end
  if not start or start == "" then
    return nil
  end

  local dir = containing_dir(absolute(start))
  while dir and dir ~= "" do
    if vim.uv.fs_stat(util.path_join(dir, "dbt_project.yml")) then
      return dir
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      return nil
    end
    dir = parent
  end
  return nil
end

function M.get_root(bufnr)
  bufnr = bufnr or 0
  local dir
  if vim.api.nvim_buf_is_valid(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then
      dir = vim.fs.dirname(absolute(name))
    end
  end
  dir = dir or vim.uv.cwd()
  if not dir then
    return nil
  end

  local cached = root_cache[dir]
  if cached ~= nil then
    return cached or nil
  end

  local root = M.find_root(dir)
  root_cache[dir] = root or false
  return root
end

function M.parse_dbt_project_yml(root_dir)
  if not root_dir or root_dir == "" then
    return nil
  end
  local content = util.read_file(util.path_join(root_dir, "dbt_project.yml"))
  if not content then
    return nil
  end

  local project = { target_path = "target" }
  for line in content:gmatch("[^\r\n]+") do
    project.name = project.name or line:match('^name:%s*"?([%w_%-]+)"?')
    project.profile = project.profile or line:match('^profile:%s*"?([%w_%-]+)"?')
    local target_path = line:match('^target%-path:%s*"?([^"%s]+)"?')
    if target_path then
      project.target_path = target_path
    end
  end
  return project
end

function M.target_dir(root_dir)
  local project = M.parse_dbt_project_yml(root_dir)
  return util.path_join(root_dir, (project and project.target_path) or "target")
end

function M.model_name_from_path(file_path, root_dir)
  if not file_path or file_path == "" or not root_dir or root_dir == "" then
    return nil
  end
  local path = file_path
  if not path:match("^/") then
    path = util.path_join(root_dir, path)
  end
  path = absolute(path)

  local models_dir = util.path_join(absolute(root_dir), "models") .. "/"
  if path:sub(1, #models_dir) ~= models_dir then
    return nil
  end
  return path:match("([^/]+)%.sql$")
end

return M
