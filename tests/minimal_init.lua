-- Minimal rtp bootstrap for plenary busted. Never sources the user's real config.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"))
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/plenary.vim")
