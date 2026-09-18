-- Load guard. setup() is NOT called here on purpose -- call
-- require("dbt-power-user").setup(opts) from your own lazy.nvim spec. :checkhealth
-- dbt-power-user works even before setup() runs (health.lua reads config.options,
-- which already has sane defaults).
if vim.g.loaded_dbt_power_user then
  return
end
vim.g.loaded_dbt_power_user = true
