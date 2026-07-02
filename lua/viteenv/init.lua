-- lua/viteenv/init.lua
-- Public API + orchestration. The only module user configs touch (via setup).
-- Wires the pieces together; no rendering/process/resolution logic itself:
--
--   config.lua   defaults + user merge
--   project.lua  root detection
--   scan.lua     find import.meta.env.VITE_X in a buffer
--   worker.lua   sidecar process lifecycle + request/response
--   cache.lua    nvim-side last-good store (powers graceful degradation)
--   lens.lua     inline extmark rendering (all modes, collapsed/fanned out)
--
-- Data flow (per buffer):
--   scan -> worker.resolve_all(root) -> cache last-good -> lens.render_modes
-- Degradation: worker down / error -> render from cache as "stale".

local M = {}

local config = require("viteenv.config")
local project = require("viteenv.project")
local scan = require("viteenv.scan")
local lens = require("viteenv.lens")
local cache = require("viteenv.cache")
local worker = require("viteenv.worker")
local watch = require("viteenv.watch")
local log = require("viteenv.log")

local DEBOUNCE_MS = 150

local aug = nil
local bufs = {} ---@type table<integer, { attached: boolean, timer: userdata|nil }>
local notified = {} ---@type table<string, boolean>  one-shot notices per root

-- Plugin-owned highlight groups, defaulted to colors DISTINCT from Comment so
-- the lens is not mistaken for code comments. `default = true` + links means
-- colorschemes/users can override freely (`:hi ViteEnvValue ...`).
local HL_DEFAULTS = {
  ViteEnvValue = "Comment", -- the value itself reads as a dim annotation
  ViteEnvMode = "Type", -- the mode label carries the color / distinction

  ViteEnvSeparator = "NonText",
  ViteEnvStale = "DiagnosticVirtualTextWarn",
  ViteEnvMissing = "DiagnosticVirtualTextHint",
}

local function define_highlights()
  for name, link in pairs(HL_DEFAULTS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

local function prefixes_of(payload)
  local p = payload and payload.envPrefix
  if type(p) == "string" then
    return { p }
  end
  return p or { "VITE_" }
end

local do_refresh -- forward declaration (watcher callback calls it)

-- Re-render every attached buffer belonging to `root` (used by the watcher).
local function refresh_root(root)
  for bufnr, st in pairs(bufs) do
    if st.attached and vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and project.root_for(name) == root then
        do_refresh(bufnr, false) -- gate decides if a real re-resolve is needed
      end
    end
  end
end

---@param bufnr integer
---@param force boolean|nil
function do_refresh(bufnr, force)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local root = project.root_for(name)
  if not root then
    log.debug("no project root for " .. name)
    lens.clear(bufnr)
    return
  end
  if #scan.scan(bufnr) == 0 then
    lens.clear(bufnr)
    return
  end

  worker.resolve_all({ root = root, force = force, only = config.options.mode }, function(res)
    if not (vim.api.nvim_buf_is_valid(bufnr) and bufs[bufnr] and bufs[bufnr].attached) then
      return
    end
    local cur = scan.scan(bufnr) -- positions may have shifted since the request
    if res.ok then
      cache.put(root, "*all", res)
      lens.render_modes(bufnr, cur, res.modeList, res.modes, { prefixes = prefixes_of(res) })
      -- watch this project's env inputs so edits refresh the lens live
      local dirs = { root }
      if res.envDir and res.envDir ~= root then
        dirs[#dirs + 1] = res.envDir
      end
      watch.ensure(root, dirs, refresh_root)
    else
      log.debug("resolve failed: " .. ((res.error and res.error.kind) or "?"))
      local kind = res.error and res.error.kind
      if (kind == "vite-not-found" or kind == "bad-vite-api") and not notified[root] then
        notified[root] = true
        log.warn(("%s in %s — lens off for this project"):format(kind, root))
      end
      local last = cache.get(root, "*all")
      if last then
        lens.render_modes(bufnr, cur, last.modeList, last.modes, { stale = true, prefixes = prefixes_of(last) })
      else
        lens.clear(bufnr)
      end
    end
  end)
end

---@param bufnr integer
---@param force boolean|nil
local function schedule_refresh(bufnr, force)
  local st = bufs[bufnr]
  if not st then
    return
  end
  if not st.timer then
    st.timer = vim.uv.new_timer()
  end
  st.timer:stop()
  st.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    do_refresh(bufnr, force)
  end))
end

-- Public API ----------------------------------------------------------------

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  aug = vim.api.nvim_create_augroup("viteenv", { clear = true })

  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = aug,
    callback = define_highlights, -- colorschemes clear custom groups; reapply
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = aug,
    pattern = config.options.filetypes,
    callback = function(ev)
      M.enable(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorHold", "InsertLeave", "TextChanged", "BufEnter" }, {
    group = aug,
    callback = function(ev)
      if bufs[ev.buf] and bufs[ev.buf].attached then
        schedule_refresh(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = aug,
    callback = function(ev)
      if bufs[ev.buf] and bufs[ev.buf].attached then
        schedule_refresh(ev.buf, true)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = aug,
    callback = function()
      watch.stop_all()
      worker.shutdown()
    end,
  })

  -- attach already-open matching buffers
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.tbl_contains(config.options.filetypes, vim.bo[b].filetype) then
      M.enable(b)
    end
  end
end

---@param bufnr integer|nil
function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  bufs[bufnr] = bufs[bufnr] or { attached = false }
  bufs[bufnr].attached = true
  do_refresh(bufnr, false)
end

---@param bufnr integer|nil
function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = bufs[bufnr]
  if st then
    if st.timer then
      st.timer:stop()
      if not st.timer:is_closing() then
        st.timer:close()
      end
    end
    st.attached = false
    st.timer = nil
  end
  lens.clear(bufnr)
end

---@param bufnr integer|nil
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if bufs[bufnr] and bufs[bufnr].attached then
    M.disable(bufnr)
  else
    M.enable(bufnr)
  end
end

--- Re-resolve and re-render, optionally forcing past the sidecar gate.
---@param opts { bufnr?: integer, force?: boolean }|nil
function M.refresh(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if bufs[bufnr] and bufs[bufnr].attached then
    do_refresh(bufnr, opts.force)
  end
end

--- Limit the lens to the given modes (nil / empty list = all discovered).
---@param modes string[]|nil
function M.set_mode(modes)
  config.options.mode = (modes and #modes > 0) and modes or nil
  for bufnr, st in pairs(bufs) do
    if st.attached then
      do_refresh(bufnr, false)
    end
  end
end

--- Restart the Node sidecar (manual recovery).
function M.restart_worker()
  worker.restart()
  M.refresh({ force = true })
end

return M
