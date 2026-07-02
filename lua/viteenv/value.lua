-- lua/viteenv/value.lua
-- Value formatting (masking + truncation) used by the inline lens.

local M = {}

local function contains_any(key, subs)
  for _, s in ipairs(subs or {}) do
    if key:find(s, 1, true) then
      return true
    end
  end
  return false
end

--- Should this key's value be masked? (matches config.lens.mask substrings)
---@param key string
function M.is_masked(key)
  return contains_any(key, require("viteenv.config").options.lens.mask)
end

--- Format a value for display: mask secrets, collapse newlines, truncate.
---@param key string
---@param val string|nil
---@param max_len integer|nil
---@return string|nil  nil when val is nil (caller decides how to show "missing")
function M.format(key, val, max_len)
  if val == nil then
    return nil
  end
  if M.is_masked(key) then
    return "••••••"
  end
  val = tostring(val):gsub("[\r\n]", " ")
  if max_len and #val > max_len then
    val = val:sub(1, max_len - 1) .. "…"
  end
  return val
end

return M
