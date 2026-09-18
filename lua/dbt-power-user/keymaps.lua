-- Wires config.options.prefix to real leader keymaps. Reuses picker.ACTIONS as the
-- single source of truth so the <leader>D* mappings never drift from the :DbtActions
-- palette (every action with a `key` gets a real mapping; the couple left keyless in
-- ACTIONS -- e.g. the downstream lineage picker -- stay palette-only on purpose, to
-- keep the leader surface from growing past what's memorisable).

local config = require("dbt-power-user.config")
local picker = require("dbt-power-user.picker")
local show = require("dbt-power-user.show")

local M = {}

local function register_which_key(prefix)
  local ok, wk = pcall(require, "which-key")
  if not ok then
    return
  end
  pcall(wk.add, { { prefix, group = "dbt", icon = { icon = "󰆼 ", color = "orange" } } })
end

function M.setup(prefix)
  prefix = prefix or config.options.prefix or "<leader>D"

  register_which_key(prefix)

  for _, action in ipairs(picker.ACTIONS) do
    if action.key then
      vim.keymap.set("n", prefix .. action.key, action.fn, { desc = "dbt: " .. action.label })
    end
  end

  vim.keymap.set("n", prefix .. "a", picker.actions, { desc = "dbt: action palette" })

  -- Visual-mode preview runs the selection instead of the whole buffer. By the time a
  -- visual-mode mapping's callback runs, Neovim has already left Visual mode and set
  -- the '< '> marks, which is exactly what show.visual_selection() reads -- no extra
  -- mode juggling needed here. ACTIONS' own normal-mode "p" (preview_query with no
  -- opts) already covers the whole-buffer case, so this is additive, not a duplicate.
  vim.keymap.set("v", prefix .. "p", function()
    show.preview_query({ range = true })
  end, { desc = "dbt: preview query (selection)" })
end

return M
