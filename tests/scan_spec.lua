local scan = require("viteenv.scan")

local function keyset(refs)
  local s = {}
  for _, r in ipairs(refs) do
    s[r.key] = true
  end
  return s
end

describe("scan", function()
  it("finds dot and bracket references", function()
    local buf = H.make_buf({
      "const a = import.meta.env.VITE_A;",
      'const b = import.meta.env["VITE_B"];',
      "const c = import.meta.env['VITE_C'];",
    }, "typescript")
    local keys = keyset(scan.scan(buf))
    ok(keys.VITE_A, "VITE_A found")
    ok(keys.VITE_B, "VITE_B (double quote) found")
    ok(keys.VITE_C, "VITE_C (single quote) found")
  end)

  it("reports correct positions", function()
    local buf = H.make_buf({ "x = import.meta.env.VITE_POS;" }, "typescript")
    local refs = scan.scan(buf)
    ok(#refs >= 1, "at least one ref")
    local r = refs[1]
    eq(r.row, 0)
    -- key ends just before the ';'
    eq(r.key, "VITE_POS")
  end)

  if H.has_parser("typescript") then
    it("ignores references inside comments and strings (treesitter)", function()
      local buf = H.make_buf({
        "// import.meta.env.VITE_COMMENT is a comment",
        'const s = "import.meta.env.VITE_STRING";',
        "const a = import.meta.env.VITE_REAL;",
      }, "typescript")
      local keys = keyset(scan.scan(buf))
      ok(keys.VITE_REAL, "real ref found")
      ok(not keys.VITE_COMMENT, "comment ref ignored")
      ok(not keys.VITE_STRING, "string ref ignored")
    end)
  else
    skip("ignores comments/strings (no typescript parser available)")
  end
end)
