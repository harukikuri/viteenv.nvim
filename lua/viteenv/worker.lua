-- lua/viteenv/worker.lua
-- Client + lifecycle manager for the Node sidecar (sidecar/worker.mjs).
-- Handles the sidecar process lifecycle and request/response correlation.
--
-- Lifecycle (status):
--   down      idle, no process; next request spawns one
--   starting  process spawned, `hello` sent, waiting for the handshake reply
--   ready     handshake ok; requests flow; queued requests flushed
--   backoff   a failure occurred; waiting before the next spawn attempt
--   broken    circuit breaker tripped; refuse to spawn until M.restart()
--
-- Requests that arrive before `ready` are queued and flushed on handshake.
-- A per-request timeout always applies. On crash/handshake-failure we restart
-- with exponential backoff; after `max_restarts` consecutive failures the
-- breaker trips. Staying `ready` for `healthy_reset_ms` resets the count.
--
-- IMPORTANT distinction: a per-request {ok=false,error} is NOT a worker failure
-- (the worker stays up); only spawn/handshake/crash failures drive restarts.

local M = {}

local W = {
  job = nil, ---@type integer|nil  jobstart channel id
  status = "down",
  pending = {}, ---@type table<integer, { cb: fun(res:table), timer: userdata }>
  queue = {}, ---@type { id: integer, obj: table }[]  awaiting handshake
  next_id = 0,
  partial = "", -- incomplete trailing stdout line
  hello_id = nil, ---@type integer|nil  id of the in-flight handshake
  restarts = 0, -- consecutive failures
  intentional_stop = false, -- swallow the on_exit we caused ourselves
  notified_broken = false,
  hello_timer = nil,
  healthy_timer = nil,
  backoff_timer = nil,
}

local function log()
  return require("viteenv.log")
end

local function cfg()
  return require("viteenv.config").options.sidecar
end

local function close_timer(t)
  if t then
    t:stop()
    if not t:is_closing() then
      t:close()
    end
  end
  return nil
end

local function sidecar_path()
  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(src, ":h:h:h") -- lua/viteenv -> repo root
  return root .. "/sidecar/worker.mjs"
end

local function send_now(obj)
  if W.job then
    vim.fn.chansend(W.job, vim.json.encode(obj) .. "\n")
  end
end

local function clear_pending(id)
  local p = W.pending[id]
  if not p then
    return nil
  end
  W.pending[id] = nil
  p.timer = close_timer(p.timer)
  return p
end

local function fail_all(err)
  local ps = W.pending
  W.pending = {}
  for id, p in pairs(ps) do
    p.timer = close_timer(p.timer)
    local cb = p.cb
    vim.schedule(function()
      cb({ ok = false, error = err, id = id })
    end)
  end
  W.queue = {}
end

-- forward declarations
local spawn_now, handle_failure

local function flush_queue()
  local q = W.queue
  W.queue = {}
  for _, item in ipairs(q) do
    if W.pending[item.id] then
      send_now(item.obj)
    end
  end
end

local function on_ready()
  W.status = "ready"
  W.hello_id = nil
  W.hello_timer = close_timer(W.hello_timer)
  W.notified_broken = false
  -- if it stays healthy for a while, forget past failures
  W.healthy_timer = close_timer(W.healthy_timer)
  W.healthy_timer = vim.uv.new_timer()
  W.healthy_timer:start(cfg().healthy_reset_ms or 10000, 0, function()
    W.restarts = 0
  end)
  flush_queue()
end

local function dispatch(line)
  if line == "" then
    return
  end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    log().debug("sidecar: unparseable line") -- protocol defense
    return
  end
  if msg.id ~= nil and msg.id == W.hello_id then
    if W.status == "starting" and msg.ok and msg.hello then
      on_ready()
    elseif W.status == "starting" then
      handle_failure("handshake returned not-ok")
    end
    return
  end
  local id = msg.id
  if id == nil then
    return
  end
  local p = clear_pending(id)
  if p then
    vim.schedule(function()
      p.cb(msg)
    end)
  end
end

local function on_stdout(_, data)
  if not data then
    return
  end
  -- jobstart line convention: data[1] continues the previous partial line;
  -- the last element is a (possibly empty) new partial.
  data[1] = W.partial .. data[1]
  W.partial = table.remove(data)
  for _, line in ipairs(data) do
    dispatch(line)
  end
end

local function on_exit(job_id, code)
  -- Ignore the exit of a job that is no longer the current one. Without this, a
  -- previous job's delayed SIGTERM exit would clobber a freshly spawned job
  -- (e.g. shutdown() immediately followed by a new request).
  if job_id ~= W.job then
    return
  end
  W.job = nil
  W.partial = ""
  if W.intentional_stop then
    W.intentional_stop = false
    return -- a stop we caused (shutdown/restart/handle_failure) — don't react
  end
  handle_failure("sidecar exited (" .. tostring(code) .. ")")
end

-- Stop the current job (if any) without triggering failure handling recursively.
local function kill_job()
  if W.job then
    W.intentional_stop = true
    pcall(vim.fn.jobstop, W.job)
    W.job = nil
  end
end

---@param reason string
function handle_failure(reason)
  log().debug("worker failure: " .. reason)
  kill_job()
  W.hello_id = nil
  W.hello_timer = close_timer(W.hello_timer)
  W.healthy_timer = close_timer(W.healthy_timer)
  fail_all({ kind = "worker-down", message = reason })

  W.restarts = W.restarts + 1
  if W.restarts > (cfg().max_restarts or 5) then
    W.status = "broken"
    if not W.notified_broken then
      W.notified_broken = true
      log().error(
        ("sidecar failed %d times — giving up; run :ViteEnvRestart to retry"):format(W.restarts)
      )
    end
    return
  end

  W.status = "backoff"
  local list = cfg().restart_backoff_ms or { 200, 400, 800, 1600, 3200 }
  local delay = list[math.min(W.restarts, #list)] or 1000
  W.backoff_timer = close_timer(W.backoff_timer)
  W.backoff_timer = vim.uv.new_timer()
  W.backoff_timer:start(delay, 0, vim.schedule_wrap(function()
    W.backoff_timer = close_timer(W.backoff_timer)
    if W.status ~= "backoff" then
      return
    end
    if next(W.pending) or #W.queue > 0 then
      spawn_now()
    else
      W.status = "down" -- go idle; next request will spawn
    end
  end))
end

function spawn_now()
  if W.status == "broken" then
    return
  end
  W.intentional_stop = false
  W.partial = ""
  -- jobstart THROWS on a non-executable command (not just <=0), so pcall it.
  local ok, job = pcall(vim.fn.jobstart, { cfg().node_path or "node", sidecar_path() }, {
    on_stdout = on_stdout,
    on_stderr = function(_, d)
      if d and #d > 0 and d[1] ~= "" then
        log().trace("sidecar stderr: " .. table.concat(d, " "))
      end
    end,
    on_exit = on_exit,
  })
  if not ok or type(job) ~= "number" or job <= 0 then
    handle_failure("spawn failed (is node on PATH?)")
    return
  end
  W.job = job
  W.status = "starting"

  -- handshake
  W.next_id = W.next_id + 1
  W.hello_id = W.next_id
  W.hello_timer = close_timer(W.hello_timer)
  W.hello_timer = vim.uv.new_timer()
  W.hello_timer:start(cfg().startup_timeout_ms or 5000, 0, vim.schedule_wrap(function()
    if W.status == "starting" then
      handle_failure("handshake timed out")
    end
  end))
  send_now({ id = W.hello_id, op = "hello" })
end

-- Shared request path for resolve / resolve-all. Queues until handshake done.
local function request(op, req, cb)
  if W.status == "broken" then
    vim.schedule(function()
      cb({ ok = false, error = { kind = "worker-down", message = "sidecar disabled (circuit breaker); run :ViteEnvRestart" } })
    end)
    return
  end

  W.next_id = W.next_id + 1
  local id = W.next_id
  local obj = { id = id, op = op, mode = req.mode, root = req.root, force = req.force or false, only = req.only }

  local timer = vim.uv.new_timer()
  timer:start(cfg().request_timeout_ms or 10000, 0, vim.schedule_wrap(function()
    local p = clear_pending(id)
    if p then
      p.cb({ ok = false, error = { kind = "timeout", message = op .. " timed out" } })
    end
  end))
  W.pending[id] = { cb = cb, timer = timer }

  if W.status == "ready" then
    send_now(obj)
  elseif W.status == "down" then
    table.insert(W.queue, { id = id, obj = obj })
    spawn_now()
  else -- starting | backoff
    table.insert(W.queue, { id = id, obj = obj })
  end
end

--- Resolve a single mode. Queues until the handshake completes.
---@param req { root: string, mode: string, force?: boolean }
---@param cb fun(res: table)  parsed JSON response (ok=true|false)
function M.resolve(req, cb)
  request("resolve", req, cb)
end

--- Resolve env for all modes at once (res.modeList + res.modes[mode]).
--- `only` (optional) limits the result to that subset of discovered modes.
---@param req { root: string, force?: boolean, only?: string[] }
---@param cb fun(res: table)
function M.resolve_all(req, cb)
  request("resolve-all", req, cb)
end

--- Liveness probe ({op="hello"}); independent of the startup handshake.
---@param cb fun(ok: boolean, info: table|nil)
function M.hello(cb)
  if W.status == "broken" then
    cb(false, nil)
    return
  end
  W.next_id = W.next_id + 1
  local id = W.next_id
  local timer = vim.uv.new_timer()
  timer:start(cfg().startup_timeout_ms or 5000, 0, vim.schedule_wrap(function()
    local p = clear_pending(id)
    if p then
      p.cb({ ok = false })
    end
  end))
  W.pending[id] = {
    cb = function(msg)
      cb(msg.ok == true and msg.hello == true, msg)
    end,
    timer = timer,
  }
  local obj = { id = id, op = "hello" }
  if W.status == "ready" then
    send_now(obj)
  elseif W.status == "down" then
    table.insert(W.queue, { id = id, obj = obj })
    spawn_now()
  else
    table.insert(W.queue, { id = id, obj = obj })
  end
end

--- Current lifecycle status (for :checkhealth / tests).
---@return string
function M.status()
  return W.status
end

--- Kill + respawn, resetting the breaker.
function M.restart()
  kill_job()
  W.hello_id = nil
  W.hello_timer = close_timer(W.hello_timer)
  W.healthy_timer = close_timer(W.healthy_timer)
  W.backoff_timer = close_timer(W.backoff_timer)
  fail_all({ kind = "worker-down", message = "restart requested" })
  W.restarts = 0
  W.notified_broken = false
  W.status = "down"
  spawn_now()
end

--- Tear down (call from VimLeavePre to avoid orphan node processes).
function M.shutdown()
  kill_job()
  W.hello_id = nil
  W.hello_timer = close_timer(W.hello_timer)
  W.healthy_timer = close_timer(W.healthy_timer)
  W.backoff_timer = close_timer(W.backoff_timer)
  fail_all({ kind = "worker-down", message = "sidecar shut down" })
  W.status = "down"
  W.partial = ""
end

M._sidecar_path = sidecar_path
return M
