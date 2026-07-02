-- lua/viteenv/scan.lua
-- Find references to Vite env in a buffer and report their positions + keys, so
-- the lens knows where to render and which keys to look up.
--
-- Targets:
--   import.meta.env.VITE_FOO        -> key "VITE_FOO"
--   import.meta.env["VITE_FOO"]     -> key "VITE_FOO"
--   import.meta.env['VITE_FOO']     -> key "VITE_FOO"
--
-- Primary path is Treesitter (accurate: ignores comments/strings). When no
-- parser is available we fall back to a line-regex scan.

local M = {}

---@class viteenv.Ref
---@field key string        the env key, e.g. "VITE_API_URL"
---@field row integer       0-indexed line
---@field col_start integer 0-indexed byte col of the reference start
---@field col_end integer   0-indexed byte col, end-exclusive

-- Matches member access (.VITE_X) and subscript (["VITE_X"]) where the object
-- is exactly `import.meta.env`. The object check is done in Lua on the matched
-- node text, which is robust across grammar versions.
local QUERY = [[
  (member_expression
    object: (_) @obj
    property: (property_identifier) @key)
  (subscript_expression
    object: (_) @obj
    index: (string (string_fragment) @skey))
]]

local function first_node(v)
  -- iter_matches values are a node (0.10) or a list of nodes (0.11+).
  if type(v) == "table" and v.range == nil then
    return v[1]
  end
  return v
end

local function scan_treesitter(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  local lang = parser:lang()
  local qok, query = pcall(vim.treesitter.query.parse, lang, QUERY)
  if not qok then
    return nil
  end

  local refs = {}
  local trees = parser:parse()
  for _, tree in ipairs(trees or {}) do
    local root = tree:root()
    for _, match in query:iter_matches(root, bufnr, 0, -1) do
      local got = {}
      for id, nodes in pairs(match) do
        got[query.captures[id]] = first_node(nodes)
      end
      if got.obj and vim.treesitter.get_node_text(got.obj, bufnr) == "import.meta.env" then
        local kn = got.key or got.skey
        if kn then
          local key = vim.treesitter.get_node_text(kn, bufnr)
          local r1, c1, _, c2 = kn:range()
          refs[#refs + 1] = { key = key, row = r1, col_start = c1, col_end = c2 }
        end
      end
    end
  end
  return refs
end

local DOT = "import%.meta%.env%.([%w_$]+)"
local BRACKET = "import%.meta%.env%[%s*[\"']([%w_$]+)[\"']%s*%]"

local function find_all(line, row, pat, refs)
  local init = 1
  while true do
    local s, e, key = line:find(pat, init)
    if not s then
      break
    end
    refs[#refs + 1] = { key = key, row = row, col_start = s - 1, col_end = e }
    init = e + 1
  end
end

local function scan_regex(bufnr)
  local refs = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    find_all(line, i - 1, DOT, refs)
    find_all(line, i - 1, BRACKET, refs)
  end
  return refs
end

--- Scan a buffer for env references.
---@param bufnr integer
---@param _prefixes string[]|nil  accepted key prefixes (filtering happens in lens)
---@return viteenv.Ref[]
function M.scan(bufnr, _prefixes)
  return scan_treesitter(bufnr) or scan_regex(bufnr)
end

return M
