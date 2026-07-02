local watch = require("viteenv.watch")

describe("watch", function()
  it("fires (debounced) on a change in a watched dir", function()
    local d = H.tmpdir()
    H.write(d .. "/.env", "A=1\n")

    local fired = 0
    watch.ensure("r1", { d }, function()
      fired = fired + 1
    end)
    ok(watch.is_watching("r1"), "watching")

    vim.wait(80, function() return false end, 10) -- let the watcher arm
    H.write(d .. "/.env", "A=2\n")

    ok(H.wait(function() return fired > 0 end, 3000), "fired on change")
    watch.stop("r1")
  end)

  it("stops firing after stop()", function()
    local d = H.tmpdir()
    H.write(d .. "/.env", "A=1\n")

    local fired = 0
    watch.ensure("r2", { d }, function()
      fired = fired + 1
    end)
    watch.stop("r2")
    ok(not watch.is_watching("r2"), "stopped")

    vim.wait(80, function() return false end, 10)
    H.write(d .. "/.env", "A=2\n")
    vim.wait(400, function() return false end, 20)
    eq(fired, 0)
  end)
end)
