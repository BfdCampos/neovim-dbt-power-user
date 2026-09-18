-- User-facing options and their defaults. Depends on nothing.

local M = {}

M.defaults = {
  prefix = "<leader>D",
  dbt_cmd = "dbt", -- absolute path override allowed
  project_dir = nil, -- nil = auto-detect (project.find_root)
  profiles_dir = nil, -- nil = dbt's own default resolution
  target = nil, -- nil = profile's own default target
  no_version_check = false,
  query_limit = 500,
  lineage = { max_depth = 5, direction = "horizontal" }, -- or "vertical"
  picker = { preview = true },
  create_model = { prefix = "stg", template = "{prefix}_{table}" },
  defer_state_path = nil, -- nil = --defer/--state unavailable until the user sets it
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
