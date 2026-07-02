-- lua/viteenv/cache.lua
-- Neovim-side "last-good" store. This is the FOUNDATION of graceful degradation
-- (docs/DESIGN.md (display tiers)): the sidecar's own cache dies with the process, so we keep a
-- copy here of every successful resolve. When the worker is down/restarting or a
-- request fails, the lens renders from here, marked "stale".
--
-- Keyed by (root, mode). Value = the last successful resolve payload + a
-- timestamp. No eviction needed at this scale (a handful of roots/modes).

local M = {}

---@type table<string, { payload: table, at: integer }>
local store = {}

local function key(root, mode)
  return root .. "\0" .. mode
end

---@param root string
---@param mode string
---@param payload table  a successful resolve response
function M.put(root, mode, payload)
  store[key(root, mode)] = { payload = payload, at = vim.uv.now() }
end

---@param root string
---@param mode string
---@return table|nil payload, integer|nil age_ms
function M.get(root, mode)
  local e = store[key(root, mode)]
  if not e then
    return nil, nil
  end
  return e.payload, vim.uv.now() - e.at
end

function M.clear()
  store = {}
end

return M
