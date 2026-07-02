-- lua/viteenv/health.lua
-- :checkhealth viteenv — verify prerequisites and exercise the live pieces
-- (sidecar handshake, a real resolve of the current project, fs_event).

local M = {}

local h = vim.health

local function check_prereqs()
  h.start("viteenv: prerequisites")

  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim 0.10+")
  else
    h.error("Neovim 0.10+ required")
  end

  local node = require("viteenv.config").options.sidecar.node_path or "node"
  if vim.fn.executable(node) == 1 then
    local ver = vim.fn.system({ node, "--version" }):gsub("%s+$", "")
    h.ok(("node found: %s (%s)"):format(node, ver))
  else
    h.error("node not found: " .. node, { "install Node.js, or set sidecar.node_path" })
  end

  local sidecar = require("viteenv.worker")._sidecar_path()
  if vim.uv.fs_stat(sidecar) then
    h.ok("sidecar present: " .. sidecar)
  else
    h.error("sidecar missing: " .. sidecar)
  end

  -- Treesitter parsers for the configured filetypes (regex fallback otherwise).
  local langs, seen = {}, {}
  for _, ft in ipairs(require("viteenv.config").options.filetypes) do
    local lang = ft
    if vim.treesitter.language.get_lang then
      lang = vim.treesitter.language.get_lang(ft) or ft
    end
    if not seen[lang] then
      seen[lang] = true
      langs[#langs + 1] = lang
    end
  end
  local have, missing = {}, {}
  for _, lang in ipairs(langs) do
    if pcall(vim.treesitter.language.add, lang) then
      have[#have + 1] = lang
    else
      missing[#missing + 1] = lang
    end
  end
  if #missing == 0 then
    h.ok("treesitter parsers: " .. table.concat(have, ", "))
  else
    h.warn("no treesitter parser for: " .. table.concat(missing, ", "), {
      "scanning falls back to regex there (may match inside comments/strings)",
      "install with nvim-treesitter, e.g. :TSInstall " .. table.concat(missing, " "),
    })
  end
end

local function check_sidecar()
  h.start("viteenv: sidecar")
  local worker = require("viteenv.worker")

  local done, alive, info
  worker.hello(function(ok, i)
    done, alive, info = true, ok, i
  end)
  vim.wait(6000, function()
    return done
  end, 50)

  if not done then
    h.error("sidecar did not respond to `hello` within timeout")
  elseif alive then
    h.ok(("sidecar responded — pid %s, node %s"):format(tostring(info and info.pid), tostring(info and info.node)))
  else
    h.error("sidecar spawn/handshake failed", { "check `node` and run :ViteEnvRestart" })
  end
  h.info("worker status: " .. worker.status())
end

-- :checkhealth runs in its own `health://` buffer, so the file the user cares
-- about is the alternate buffer.
local function target_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and not name:match("^health://") then
    return buf, name
  end
  local alt = vim.fn.bufnr("#")
  if alt > 0 and vim.api.nvim_buf_is_valid(alt) then
    return alt, vim.api.nvim_buf_get_name(alt)
  end
  return buf, name
end

local function check_project()
  h.start("viteenv: current project")

  local buf, name = target_buffer()
  if name == "" or name:match("^health://") then
    h.info("open a project file, then run :checkhealth viteenv to probe it")
    return
  end

  local root = require("viteenv.project").root_for(name)
  if not root then
    h.warn("no Vite project root found upward from " .. name)
    return
  end
  h.ok("project root: " .. root)

  -- Treesitter parser drives accurate scanning (regex fallback otherwise)
  local ft = vim.bo[buf].filetype
  local lang = ft
  if vim.treesitter.language.get_lang then
    lang = vim.treesitter.language.get_lang(ft) or ft
  end
  if ft ~= "" and pcall(vim.treesitter.language.add, lang) then
    h.ok(("treesitter parser for '%s' (accurate scanning)"):format(ft))
  else
    h.warn(("no treesitter parser for '%s' — using regex fallback"):format(ft ~= "" and ft or "?"))
  end

  local res
  require("viteenv.worker").resolve_all({ root = root, force = true }, function(r)
    res = r
  end)
  vim.wait(10000, function()
    return res ~= nil
  end, 50)

  if not res then
    h.error("resolve timed out")
  elseif res.ok then
    h.ok(("resolved with vite %s"):format(tostring(res.viteVersion)))
    h.info("modes: " .. table.concat(res.modeList, ", "))
  elseif res.error and res.error.kind == "vite-not-found" then
    h.warn("vite not resolvable from this root — the lens is off here")
  else
    h.error(("resolve failed (%s)"):format(res.error and res.error.kind or "?"), { res.error and res.error.message or "" })
  end
end

local function check_watcher()
  h.start("viteenv: watcher")
  local watch = require("viteenv.watch")

  -- Functional test: fs_event on a throwaway dir must fire on a write.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function write(v)
    local f = io.open(dir .. "/.env", "w")
    if f then
      f:write("A=" .. v .. "\n")
      f:close()
    end
  end
  write("1")
  local fired = false
  watch.ensure("__viteenv_healthcheck__", { dir }, function()
    fired = true
  end)
  vim.wait(80, function()
    return false
  end, 10)
  write("2")
  vim.wait(2000, function()
    return fired
  end, 50)
  watch.stop("__viteenv_healthcheck__")

  if fired then
    h.ok("filesystem watch (fs_event) works — live refresh on .env changes")
  else
    h.warn("fs_event did not fire — live refresh may not work on this filesystem")
  end

  local roots = watch.list()
  if #roots == 0 then
    h.info("no projects currently watched (open a project file)")
  else
    h.ok(("watching %d project(s)"):format(#roots))
    for _, r in ipairs(roots) do
      h.info("  " .. r)
    end
  end
end

function M.check()
  check_prereqs()
  check_sidecar()
  check_project()
  check_watcher()
end

return M
