-- lua/viteenv/lens.lua
-- Inline rendering: end-of-line virtual text showing every shown mode's value
-- for each import.meta.env.VITE_X reference. When all modes agree the value
-- collapses to ` = value`; when they differ it fans out per mode. Secrets are
-- masked and long values truncated (see value.lua). Degradation: a stale flag
-- switches values to the "stale" highlight.
--
-- Pure rendering: no resolution, no process, no scanning here.

local M = {}

local ns = vim.api.nvim_create_namespace("viteenv")
M.ns = ns

local value = require("viteenv.value")

local function has_prefix(key, prefixes)
  for _, p in ipairs(prefixes or {}) do
    if key:sub(1, #p) == p then
      return true
    end
  end
  return false
end

-- Build the virt_text chunks for one key across all modes, collapsing to a
-- single value when every mode agrees.
local function build_multi(key, modeList, modes, cfg, stale)
  local hlv = stale and cfg.highlights.stale or cfg.highlights.value

  local raws, any_present, saw_nil = {}, false, false
  local uniq, nuniq = {}, 0
  for _, m in ipairs(modeList) do
    local r = modes[m] and modes[m][key]
    raws[m] = r
    if r == nil then
      saw_nil = true
    else
      any_present = true
      if uniq[r] == nil then
        uniq[r] = true
        nuniq = nuniq + 1
      end
    end
  end

  -- Unified format: everything is `[label ]= value`. Collapsed has no label;
  -- per-mode prefixes each with its mode name. The `= ` connector and the value
  -- highlight are the same in both.
  local sep_hl = cfg.highlights.separator
  local function value_chunk(v, max_len)
    if v == nil then
      return { "unset", cfg.highlights.missing }
    end
    return { value.format(key, v, max_len), hlv }
  end

  local chunks
  if not any_present then
    chunks = { { cfg.prefix, sep_hl }, { "unset", cfg.highlights.missing } }
  elseif cfg.collapse and nuniq == 1 and not saw_nil then
    -- collapsed: all modes present and equal
    chunks = { { cfg.prefix, sep_hl }, value_chunk(raws[modeList[1]], cfg.max_value_len) }
  else
    -- per-mode: values differ (or some modes are unset)
    chunks = {}
    for i, m in ipairs(modeList) do
      if i > 1 then
        chunks[#chunks + 1] = { cfg.separator or "  ", sep_hl }
      end
      local label = (cfg.mode_labels and cfg.mode_labels[m]) or m
      chunks[#chunks + 1] = { label .. " ", cfg.highlights.mode }
      chunks[#chunks + 1] = { cfg.prefix, sep_hl }
      chunks[#chunks + 1] = value_chunk(raws[m], cfg.mode_value_len)
    end
  end

  return chunks
end

local function renderable(key, modeList, modes, prefixes)
  for _, m in ipairs(modeList) do
    if modes[m] and modes[m][key] ~= nil then
      return true
    end
  end
  return has_prefix(key, prefixes)
end

--- Render every mode's value for each reference. Annotations are aligned to a
--- uniform column (just past the longest annotated line) via virt_text_win_col.
---@param bufnr integer
---@param refs viteenv.Ref[]
---@param modeList string[]
---@param modes table<string, table<string,string>>
---@param opts { stale?: boolean, prefixes?: string[] }|nil
function M.render_modes(bufnr, refs, modeList, modes, opts)
  opts = opts or {}
  local cfg = require("viteenv.config").options.lens
  local prefixes = opts.prefixes or { "VITE_" }
  M.clear(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- pass 1: pick renderable refs, count per row, find the alignment column
  local todo, per_row, max_w = {}, {}, 0
  for _, ref in ipairs(refs) do
    if renderable(ref.key, modeList, modes, prefixes) then
      todo[#todo + 1] = ref
      per_row[ref.row] = (per_row[ref.row] or 0) + 1
      local w = vim.fn.strdisplaywidth(lines[ref.row + 1] or "")
      if w > max_w then
        max_w = w
      end
    end
  end
  local col = max_w + (cfg.padding or 1)

  -- pass 2: render
  for _, ref in ipairs(todo) do
    local chunks = build_multi(ref.key, modeList, modes, cfg, opts.stale)
    if per_row[ref.row] == 1 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, ref.row, 0, {
        virt_text = chunks,
        virt_text_win_col = col,
        hl_mode = "combine",
      })
    else
      -- multiple refs on one line can't all sit at the same column; fall back to
      -- eol so they read left-to-right instead of overlapping.
      table.insert(chunks, 1, { "  " })
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, ref.row, 0, {
        virt_text = chunks,
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

--- Clear all lens extmarks from a buffer.
---@param bufnr integer
function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

return M
