-- lua/viteenv/config.lua
-- Default configuration + user merge. No behavior here, just data.

local M = {}

---@class viteenv.Config
M.defaults = {
  -- Filetypes the lens attaches to.
  filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact", "vue", "svelte" },

  -- Limit which modes are shown. nil / empty = every auto-discovered mode.
  -- Set a list to restrict, e.g. { "development", "production" }. Modes are
  -- always auto-discovered (package.json `--mode` scripts + `.env.<mode>`
  -- files); this only filters that set.
  ---@type string[]|nil
  mode = nil,

  -- Inline rendering (end-of-line virtual text showing every shown mode).
  lens = {
    collapse = true, -- when all shown modes share a value, show it once
    padding = 8, -- spaces between end of code and the annotation
    prefix = "= ", -- separator before a single/collapsed value
    separator = " │ ", -- divider between modes when they differ
    max_value_len = 60, -- truncate a single/collapsed value
    mode_value_len = 32, -- truncate each value in the per-mode (differing) view
    mask = { "SECRET", "TOKEN", "PASSWORD", "PRIVATE" }, -- substrings -> value masked
    -- Display labels for modes. Empty = the real mode name (matches your
    -- .env.<mode> files). Opt into shorter labels, e.g.
    --   mode_labels = { development = "dev", production = "prod" }
    mode_labels = {},
    -- Highlight groups. These are the plugin's own groups (set up with defaults
    -- that are DISTINCT from `Comment` so the lens doesn't look like code
    -- comments). Override the groups (`:hi ViteEnvValue ...`) or point these at
    -- your own groups.
    highlights = {
      value = "ViteEnvValue",
      mode = "ViteEnvMode", -- the mode label in the per-mode view
      separator = "ViteEnvSeparator", -- the divider between modes
      stale = "ViteEnvStale", -- Tier 1: last-good shown while refreshing
      missing = "ViteEnvMissing", -- referenced VITE_X not present in env
    },
  },

  -- Node sidecar.
  sidecar = {
    ---@type string|nil  absolute path to node; nil = "node" on PATH
    node_path = nil,
    startup_timeout_ms = 5000, -- wait for `hello` after spawn
    request_timeout_ms = 10000, -- per resolve (cold + net-I/O safe)
    restart_backoff_ms = { 200, 400, 800, 1600, 3200 },
    max_restarts = 5, -- consecutive failures before the breaker trips
    healthy_reset_ms = 10000, -- stay ready this long -> reset the failure count
  },

  -- Logging. levels: "trace"|"debug"|"info"|"warn"|"error"|"off"
  log_level = "warn",
}

---@type viteenv.Config
M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
