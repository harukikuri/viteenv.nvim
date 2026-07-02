local health = require("viteenv.health")

describe("health", function()
  it("exposes check()", function()
    eq(type(health.check), "function")
  end)

  if not H.example_ready() then
    skip("checkhealth integration needs the example app")
    return
  end

  it(":checkhealth viteenv reports the project as healthy", function()
    require("viteenv.config").setup({})
    require("viteenv.worker").shutdown()

    vim.cmd.edit(H.example_app() .. "/src/config.ts")
    vim.bo.filetype = "typescript"
    vim.cmd("silent checkhealth viteenv")

    local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    ok(report:find("sidecar responded", 1, true), "sidecar liveness reported")
    ok(report:find("resolved with vite", 1, true), "project resolved")
    ok(report:find("fs_event", 1, true), "watcher checked")
    ok(not report:find("ERROR", 1, true), "no ERROR in report:\n" .. report)

    require("viteenv.watch").stop_all()
    require("viteenv.worker").shutdown()
  end)
end)
