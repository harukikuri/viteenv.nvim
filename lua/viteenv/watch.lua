-- lua/viteenv/watch.lua
-- Filesystem watcher for a project's env inputs. Watches the root (and envDir,
-- if different) DIRECTORIES — non-recursively — so a change to `.env*`,
-- `vite.config.*`, or a newly added/removed `.env.<mode>` fires a callback,
-- while churn in subdirectories (src/, node_modules/) does not.
--
-- Watching the directory (not each file) survives atomic saves (rename/replace),
-- which would otherwise invalidate a per-file watch. The callback is debounced
-- to coalesce the burst of events an editor emits per save.

local M = {}

-- root -> { handles = { uv_fs_event, ... }, timer = uv_timer|nil, cb = fun }
local watched = {}

local DEBOUNCE_MS = 120

local function fire(root)
  local w = watched[root]
  if not w then
    return
  end
  if not w.timer then
    w.timer = vim.uv.new_timer()
  end
  w.timer:stop()
  w.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    local cur = watched[root]
    if cur and cur.cb then
      cur.cb(root)
    end
  end))
end

--- Ensure `dirs` are watched for `root`. `cb(root)` fires (debounced) on change.
--- Idempotent: a second call for the same root just refreshes the callback.
---@param root string
---@param dirs string[]
---@param cb fun(root: string)
function M.ensure(root, dirs, cb)
  local w = watched[root]
  if w then
    w.cb = cb
    return
  end
  w = { handles = {}, cb = cb }
  watched[root] = w

  for _, dir in ipairs(dirs) do
    local handle = vim.uv.new_fs_event()
    if handle then
      local ok = pcall(function()
        handle:start(dir, {}, function(err)
          if not err then
            fire(root)
          end
        end)
      end)
      if ok then
        w.handles[#w.handles + 1] = handle
      else
        pcall(function()
          handle:close()
        end)
      end
    end
  end
end

--- Stop watching a root.
---@param root string
function M.stop(root)
  local w = watched[root]
  if not w then
    return
  end
  for _, h in ipairs(w.handles) do
    pcall(function()
      h:stop()
      h:close()
    end)
  end
  if w.timer then
    w.timer:stop()
    if not w.timer:is_closing() then
      w.timer:close()
    end
  end
  watched[root] = nil
end

--- Stop all watchers (call from VimLeavePre).
function M.stop_all()
  for root in pairs(watched) do
    M.stop(root)
  end
end

--- Is a root currently watched? (for tests / introspection)
---@param root string
---@return boolean
function M.is_watching(root)
  return watched[root] ~= nil
end

return M
