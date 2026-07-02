-- lua/viteenv/project.lua
-- Project resolution: given a buffer/path, find the Vite project root and decide
-- which mode to resolve against. The sidecar does the heavy lifting; this just
-- picks the right (root, mode) inputs to feed it.

local M = {}

local VITE_CONFIGS = {
  "vite.config.ts",
  "vite.config.js",
  "vite.config.mjs",
  "vite.config.cjs",
  "vite.config.mts",
  "vite.config.cts",
}

local cache = {} ---@type table<string, string|false>

--- Find the project root for a path: nearest ancestor with a vite config, else
--- nearest package.json. Cached per directory.
---@param path string  absolute file path (or dir)
---@return string|nil root
function M.root_for(path)
  local dir = vim.fn.fnamemodify(path, ":p")
  if vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  if cache[dir] ~= nil then
    return cache[dir] or nil
  end

  local found_pkg = nil
  local cur = dir
  while cur and cur ~= "" do
    for _, name in ipairs(VITE_CONFIGS) do
      if vim.uv.fs_stat(cur .. "/" .. name) then
        cache[dir] = cur
        return cur
      end
    end
    if not found_pkg and vim.uv.fs_stat(cur .. "/package.json") then
      found_pkg = cur
    end
    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur then
      break
    end
    cur = parent
  end

  cache[dir] = found_pkg or false
  return found_pkg
end

return M
