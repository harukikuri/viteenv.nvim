local worker = require("viteenv.worker")
local config = require("viteenv.config")

describe("worker (integration)", function()
  if not H.example_ready() then
    skip("needs node + `npm install` in examples/react-app")
    return
  end

  local app = H.example_app()

  it("resolves dev and prod through the handshake", function()
    config.setup({})
    worker.shutdown()

    local dev
    worker.resolve({ root = app, mode = "development" }, function(r)
      dev = r
    end)
    ok(H.wait(function() return dev ~= nil end, 10000), "dev responded")
    ok(dev.ok, "dev resolve failed: " .. vim.inspect(dev.error))
    eq(dev.env.VITE_API_URL, "http://localhost:3000/v1")
    eq(worker.status(), "ready")

    local prod
    worker.resolve({ root = app, mode = "production" }, function(r)
      prod = r
    end)
    ok(H.wait(function() return prod ~= nil end, 10000), "prod responded")
    ok(prod.ok, "prod resolve failed: " .. vim.inspect(prod.error))
    eq(prod.env.VITE_API_URL, "https://api.prod.example.com/v1")
  end)

  it("resolve_all returns every mode (incl. discovered custom modes)", function()
    config.setup({})
    worker.shutdown()

    local res
    worker.resolve_all({ root = app }, function(r)
      res = r
    end)
    ok(H.wait(function() return res ~= nil end, 10000), "resolve_all responded")
    ok(res.ok, "resolve_all failed: " .. vim.inspect(res.error))
    ok(vim.tbl_contains(res.modeList, "development"), "has development")
    ok(vim.tbl_contains(res.modeList, "production"), "has production")
    ok(vim.tbl_contains(res.modeList, "staging"), "discovers .env.staging mode")
    eq(res.modes.development.VITE_API_URL, "http://localhost:3000/v1")
    eq(res.modes.production.VITE_API_URL, "https://api.prod.example.com/v1")
    eq(res.modes.staging.VITE_API_URL, "https://api.staging.example.com/v1")
  end)

  -- A throwaway project that resolves the example's vite via a symlink, so we
  -- can control package.json / .env without touching the example.
  local function mkproj(package_json)
    local d = H.tmpdir()
    H.write(d .. "/package.json", package_json)
    vim.uv.fs_symlink(app .. "/node_modules", d .. "/node_modules")
    return d
  end

  local function resolve_all_sync(req)
    local res
    worker.resolve_all(req, function(r)
      res = r
    end)
    ok(H.wait(function() return res ~= nil end, 10000), "resolve_all responded")
    ok(res.ok, "resolve_all failed: " .. vim.inspect(res.error))
    return res
  end

  it("mode filter: `only` limits the discovered set", function()
    config.setup({})
    worker.shutdown()
    -- .env.staging is discovered, but `only` restricts to a subset
    local res = resolve_all_sync({ root = app, only = { "development", "production" } })
    eq(res.modeList, { "development", "production" })
  end)

  it("mode discovery: from package.json scripts, no env files needed", function()
    config.setup({})
    worker.shutdown()
    local d = mkproj([[{
      "type": "module",
      "scripts": {
        "dev": "vite",
        "build": "tsc -b && vite build",
        "build:preview": "vite build --mode preview"
      }
    }]])
    local res = resolve_all_sync({ root = d })
    -- development + production inferred from vite/vite build; preview from --mode
    eq(res.modeList, { "development", "production", "preview" })
  end)

  it("mode discovery: falls back to development/production when nothing is declared", function()
    config.setup({})
    worker.shutdown()
    local d = mkproj([[{ "type": "module", "scripts": { "lint": "eslint ." } }]])
    local res = resolve_all_sync({ root = d })
    eq(res.modeList, { "development", "production" })
  end)

  it("trips the breaker on repeated spawn failure and recovers on restart", function()
    worker.shutdown()
    config.setup({
      log_level = "off",
      sidecar = {
        node_path = "/nonexistent/node-xyzzy",
        startup_timeout_ms = 200,
        request_timeout_ms = 1500,
        restart_backoff_ms = { 10, 10, 10, 10 },
        max_restarts = 2,
        healthy_reset_ms = 60000,
      },
    })

    for _ = 1, 5 do
      worker.resolve({ root = app, mode = "development" }, function() end)
      vim.wait(60, function() return false end, 10)
    end
    ok(H.wait(function() return worker.status() == "broken" end, 3000), "breaker tripped")

    -- fast-fail while broken
    local fast
    worker.resolve({ root = app, mode = "development" }, function(r)
      fast = r
    end)
    ok(H.wait(function() return fast ~= nil end, 1000), "responded while broken")
    eq(fast.error.kind, "worker-down")

    -- recover
    config.setup({})
    worker.restart()
    local rec
    worker.resolve({ root = app, mode = "development" }, function(r)
      rec = r
    end)
    ok(H.wait(function() return rec ~= nil end, 10000), "recovery responded")
    ok(rec.ok, "recovered ok")
    eq(worker.status(), "ready")
    worker.shutdown()
  end)
end)
