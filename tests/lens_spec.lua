local lens = require("viteenv.lens")
local config = require("viteenv.config")

local function marks_by_row(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, lens.ns, 0, -1, { details = true })) do
    local parts = {}
    for _, c in ipairs(m[4].virt_text) do
      parts[#parts + 1] = c[1]
    end
    out[m[2]] = table.concat(parts)
  end
  return out
end

describe("lens.render_modes", function()
  it("collapses equal values and fans out differing ones", function()
    config.setup({})
    local buf = H.make_buf({ "a", "b" }, "typescript")
    lens.render_modes(buf, {
      { key = "VITE_SAME", row = 0, col_start = 0, col_end = 1 },
      { key = "VITE_DIFF", row = 1, col_start = 0, col_end = 1 },
    }, { "development", "production" }, {
      development = { VITE_SAME = "x", VITE_DIFF = "d" },
      production = { VITE_SAME = "x", VITE_DIFF = "p" },
    }, { prefixes = { "VITE_" } })

    local by = marks_by_row(buf)
    local pfx = config.options.lens.prefix -- "= "
    ok(by[0]:find(pfx .. "x", 1, true), "collapsed to one value")
    -- unified `label = value` format
    ok(by[1]:find("development " .. pfx .. "d", 1, true), "development = d")
    ok(by[1]:find("production " .. pfx .. "p", 1, true), "production = p")
  end)

  it("aligns annotations at a uniform column", function()
    config.setup({})
    local long = "a_much_longer_variable_line = y"
    local buf = H.make_buf({ "x = a", long }, "typescript")
    lens.render_modes(buf, {
      { key = "VITE_A", row = 0, col_start = 0, col_end = 1 },
      { key = "VITE_B", row = 1, col_start = 0, col_end = 1 },
    }, { "development" }, { development = { VITE_A = "1", VITE_B = "2" } }, { prefixes = { "VITE_" } })

    local cols = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, lens.ns, 0, -1, { details = true })) do
      cols[#cols + 1] = m[4].virt_text_win_col
    end
    eq(#cols, 2)
    ok(cols[1] ~= nil, "alignment column is set")
    eq(cols[1], cols[2]) -- both annotations share the same column
    ok(cols[1] >= #long, "column clears the longest annotated line")
  end)

  it("masks secrets and marks unset per mode", function()
    config.setup({})
    local buf = H.make_buf({ "a", "b" }, "typescript")
    lens.render_modes(buf, {
      { key = "VITE_API_TOKEN", row = 0, col_start = 0, col_end = 1 },
      { key = "VITE_ONLY_DEV", row = 1, col_start = 0, col_end = 1 },
    }, { "development", "production" }, {
      development = { VITE_API_TOKEN = "abc", VITE_ONLY_DEV = "yes" },
      production = { VITE_API_TOKEN = "xyz" }, -- VITE_ONLY_DEV absent here
    }, { prefixes = { "VITE_" } })

    local by = marks_by_row(buf)
    local pfx = config.options.lens.prefix
    ok(by[0]:find("••••••", 1, true), "token masked")
    ok(not by[0]:find("abc", 1, true), "raw token hidden")
    ok(by[1]:find("development " .. pfx .. "yes", 1, true), "present in dev")
    ok(by[1]:find("production " .. pfx .. "unset", 1, true), "unset in prod")
  end)

  it("skips non-prefixed keys (built-ins like MODE)", function()
    config.setup({})
    local buf = H.make_buf({ "a" }, "typescript")
    lens.render_modes(buf, { { key = "MODE", row = 0, col_start = 0, col_end = 1 } }, { "development" }, {
      development = {},
    }, { prefixes = { "VITE_" } })
    eq(#vim.api.nvim_buf_get_extmarks(buf, lens.ns, 0, -1, {}), 0)
  end)

  it("clear removes all marks", function()
    config.setup({})
    local buf = H.make_buf({ "a" }, "typescript")
    lens.render_modes(buf, { { key = "VITE_X", row = 0, col_start = 0, col_end = 1 } }, { "development" }, {
      development = { VITE_X = "1" },
    }, { prefixes = { "VITE_" } })
    lens.clear(buf)
    eq(#vim.api.nvim_buf_get_extmarks(buf, lens.ns, 0, -1, {}), 0)
  end)
end)
