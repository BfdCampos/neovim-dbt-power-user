-- Compiled-SQL preview for a model, rendered in a floating nui popup.

local job = require("dbt-power-user.job")
local project = require("dbt-power-user.project")
local util = require("dbt-power-user.util")

local M = {}

-- Under --quiet dbt prints the CompiledNode payload on its own, but an ERROR-level
-- warning can still land ahead of it, so decode the outermost object rather than
-- assuming stdout is nothing but JSON.
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

local function current_model()
  local root = project.get_root(0)
  if not root then
    return nil
  end
  return project.model_name_from_path(vim.api.nvim_buf_get_name(0), root)
end

local function open_popup(title, sql)
  local ok, Popup = pcall(require, "nui.popup")
  if not ok then
    util.notify("nui.nvim is required for the compiled SQL preview", vim.log.levels.ERROR)
    return nil
  end

  local popup = Popup({
    enter = true,
    focusable = true,
    position = "50%",
    size = { width = "80%", height = "80%" },
    border = { style = "rounded", text = { top = " " .. title .. " ", top_align = "center" } },
    buf_options = { modifiable = true, readonly = false, filetype = "sql" },
    win_options = { wrap = false, number = true, cursorline = true },
  })

  popup:mount()

  -- Filled before the buffer is locked down; setting 'readonly' first only earns a W10.
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, vim.split(sql, "\n", { plain = true }))
  vim.bo[popup.bufnr].modifiable = false
  vim.bo[popup.bufnr].readonly = true

  for _, key in ipairs({ "q", "<Esc>" }) do
    popup:map("n", key, function()
      popup:unmount()
    end, { noremap = true, nowait = true })
  end

  return popup
end

function M.preview(model_name)
  model_name = model_name or current_model()
  if not model_name or model_name == "" then
    util.notify("current buffer is not a dbt model", vim.log.levels.WARN)
    return nil
  end

  return job.run_dbt({
    "compile",
    "--select",
    model_name,
    "--output",
    "json",
    "--quiet",
    "--no-use-colors",
  }, {
    on_exit = function(res)
      if res.code ~= 0 then
        return util.notify(util.job_failure_message("compile", res), vim.log.levels.ERROR)
      end

      local data = decode_payload(res.stdout)
      if not data then
        return util.notify("could not parse dbt output", vim.log.levels.ERROR)
      end

      local compiled = data.compiled
      if type(compiled) ~= "string" or compiled == "" then
        return util.notify("no compiled SQL returned for " .. model_name, vim.log.levels.WARN)
      end

      open_popup("Compiled SQL: " .. model_name, compiled)
    end,
  })
end

return M
