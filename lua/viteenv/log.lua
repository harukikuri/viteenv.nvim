-- lua/viteenv/log.lua
-- Tiny leveled logger gated by config.log_level. Keeps sidecar stderr and
-- internal diagnostics out of the user's way unless they opt in.

local M = {}

local order = { trace = 1, debug = 2, info = 3, warn = 4, error = 5, off = 99 }

local function enabled(level)
  local cfg = require("viteenv.config").options
  return order[level] >= order[cfg.log_level or "warn"]
end

---@param level "trace"|"debug"|"info"|"warn"|"error"
---@param msg string
function M.log(level, msg)
  if not enabled(level) then
    return
  end
  local lvl = ({
    trace = vim.log.levels.TRACE,
    debug = vim.log.levels.DEBUG,
    info = vim.log.levels.INFO,
    warn = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
  })[level] or vim.log.levels.INFO
  vim.schedule(function()
    vim.notify("[viteenv] " .. msg, lvl)
  end)
end

for _, l in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  M[l] = function(msg)
    M.log(l, msg)
  end
end

return M
