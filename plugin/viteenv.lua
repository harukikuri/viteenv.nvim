-- plugin/viteenv.lua
-- Entry point loaded by Neovim at startup. Keep this thin: guard against double
-- load, define user commands, and wire autocmds. All real work lives in
-- lua/viteenv/*. Heavy modules are required lazily so startup stays cheap.

if vim.g.loaded_viteenv then
  return
end
vim.g.loaded_viteenv = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("[viteenv] requires Neovim 0.10+", vim.log.levels.WARN)
  return
end

-- User commands -------------------------------------------------------------
local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

cmd("ViteEnvEnable", function()
  require("viteenv").enable()
end, { desc = "Enable the Vite env lens in the current buffer" })

cmd("ViteEnvDisable", function()
  require("viteenv").disable()
end, { desc = "Disable the Vite env lens in the current buffer" })

cmd("ViteEnvToggle", function()
  require("viteenv").toggle()
end, { desc = "Toggle the Vite env lens" })

cmd("ViteEnvRefresh", function()
  require("viteenv").refresh({ force = true })
end, { desc = "Force re-resolve (bypass the sidecar mtime gate)" })

cmd("ViteEnvMode", function(o)
  local modes = o.fargs
  require("viteenv").set_mode(#modes > 0 and modes or nil)
end, { nargs = "*", desc = "Limit the lens to these modes (no args = all discovered)" })

cmd("ViteEnvRestart", function()
  require("viteenv").restart_worker()
end, { desc = "Restart the Node sidecar worker" })

-- NOTE: autocmds are registered from require("viteenv").setup() so they respect
-- user config (filetypes).
