-- lua/viteenv/health.lua
-- :checkhealth viteenv — verify the runtime prerequisites the plugin depends on.

local M = {}

function M.check()
  local h = vim.health
  h.start("viteenv")

  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim 0.10+")
  else
    h.error("Neovim 0.10+ required")
  end

  local node = require("viteenv.config").options.sidecar.node_path or "node"
  if vim.fn.executable(node) == 1 then
    h.ok("node found: " .. node)
  else
    h.error("node not found on PATH (set sidecar.node_path)")
  end

  local worker = require("viteenv.worker")._sidecar_path()
  if vim.uv.fs_stat(worker) then
    h.ok("sidecar present: " .. worker)
  else
    h.error("sidecar/worker.mjs missing: " .. worker)
  end

  -- TODO: probe the current buffer's project — does it have a local vite?
  --       (run a `hello` + a resolve and report viteVersion / kind).
end

return M
