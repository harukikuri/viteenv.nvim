local value = require("viteenv.value")

describe("value.format", function()
  it("masks secret-ish keys", function()
    require("viteenv.config").setup({})
    eq(value.format("VITE_API_TOKEN", "abc", 80), "••••••")
    eq(value.format("VITE_SESSION_SECRET", "x", 80), "••••••")
    eq(value.format("VITE_DB_PASSWORD", "x", 80), "••••••")
  end)

  it("passes normal values through", function()
    require("viteenv.config").setup({})
    eq(value.format("VITE_URL", "http://x", 80), "http://x")
    -- PUBLIC_KEY must NOT be masked by default
    eq(value.format("VITE_PUBLIC_KEY", "pk_1", 80), "pk_1")
  end)

  it("truncates to max_len with an ellipsis", function()
    require("viteenv.config").setup({})
    local out = value.format("VITE_LONG", "0123456789ABCDE", 8)
    ok(out:find("…", 1, true), "has ellipsis")
    ok(vim.fn.strchars(out) <= 8, "clamped to <=8 chars")
  end)

  it("returns nil for a nil value", function()
    eq(value.format("VITE_X", nil, 80), nil)
  end)

  it("collapses newlines", function()
    require("viteenv.config").setup({})
    eq(value.format("VITE_M", "a\nb", 80), "a b")
  end)
end)
