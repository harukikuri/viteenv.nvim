local config = require("viteenv.config")

describe("config", function()
  it("merges user opts over defaults (deep)", function()
    config.setup({ mode = { "production" }, lens = { prefix = " => " } })
    eq(config.options.mode, { "production" })
    eq(config.options.lens.prefix, " => ")
    -- sibling lens defaults preserved through the deep merge
    ok(config.options.lens.max_value_len ~= nil, "max_value_len kept")
    ok(vim.tbl_contains(config.options.filetypes, "typescriptreact"), "default filetypes kept")
  end)

  it("resets to defaults on empty setup", function()
    config.setup({})
    eq(config.options.mode, nil)
    eq(config.options.lens.prefix, config.defaults.lens.prefix)
  end)
end)
