-- Public entry point. Call require("dbt-power-user").setup(opts) from your lazy.nvim
-- spec's `opts` (or `config`) -- see README.md for the full LazyVim spec example.

local commands = require("dbt-power-user.commands")
local config = require("dbt-power-user.config")
local definition = require("dbt-power-user.definition")
local diagnostics = require("dbt-power-user.diagnostics")
local keymaps = require("dbt-power-user.keymaps")
local manifest = require("dbt-power-user.manifest")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

local watched_roots = {}

-- Re-check every open sql/yaml buffer against `root` and refresh its diagnostics.
-- Called after a manifest change, when we don't know which buffer(s) it affects.
local function refresh_buffers_for_root(root)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local ft = vim.bo[bufnr].filetype
      if (ft == "sql" or ft == "yaml") and project.get_root(bufnr) == root then
        diagnostics.refresh_buffer(bufnr, root)
      end
    end
  end
end

local function watch_once(root)
  if watched_roots[root] then
    return
  end
  watched_roots[root] = true
  manifest.watch(root, function(changed_root)
    refresh_buffers_for_root(changed_root)
    util.notify("dbt manifest updated")
  end)
end

local function on_filetype(args)
  local bufnr = args.buf
  local root = config.options.project_dir or project.get_root(bufnr)
  if not root then
    return
  end

  definition.setup_buffer(bufnr)
  diagnostics.refresh_buffer(bufnr, root)
  watch_once(root)

  -- gd is the only bare keymap taken over, and only in dbt-project sql buffers -- `K`
  -- stays untouched (it's 'keywordprg' by default, and often already rebound to LSP
  -- hover; hover here lives at <leader>Dk instead so it never competes for the key).
  if vim.bo[bufnr].filetype == "sql" then
    vim.keymap.set("n", "gd", definition.goto_under_cursor, { buffer = bufnr, desc = "dbt: go to definition" })
  end
end

function M.setup(opts)
  config.setup(opts)
  commands.setup()
  keymaps.setup(config.options.prefix)

  vim.api.nvim_create_autocmd("FileType", {
    pattern = { "sql", "yaml" },
    group = vim.api.nvim_create_augroup("dbt-power-user", { clear = true }),
    callback = on_filetype,
  })

  -- A buffer may already have its filetype set before setup() runs (e.g. setup() is
  -- called from a `cmd`/`keys`-triggered lazy load after the file opened).
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local ft = vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype
    if ft == "sql" or ft == "yaml" then
      on_filetype({ buf = bufnr })
    end
  end
end

return M
