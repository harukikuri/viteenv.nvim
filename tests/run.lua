-- tests/run.lua — dependency-free test runner.
-- Run with:  nvim --headless -u NONE -l tests/run.lua   (or `make test`)
-- Exits nonzero if any spec fails.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:append(root)

local results = { pass = 0, fail = 0, skip = 0, fails = {} }
local current = "?"

function _G.describe(name, fn)
  current = name
  local ok, err = pcall(fn)
  if not ok then
    results.fail = results.fail + 1
    table.insert(results.fails, ("%s: <error loading describe> %s"):format(name, err))
    io.write("E")
  end
end

function _G.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    results.pass = results.pass + 1
    io.write(".")
  else
    results.fail = results.fail + 1
    table.insert(results.fails, ("%s > %s\n    %s"):format(current, name, tostring(err)))
    io.write("F")
  end
end

function _G.skip(name)
  results.skip = results.skip + 1
  io.write("s")
end

function _G.eq(got, want, msg)
  if not vim.deep_equal(got, want) then
    error(
      (msg or "eq failed")
        .. ("\n    want: %s\n    got:  %s"):format(vim.inspect(want), vim.inspect(got)),
      2
    )
  end
end

function _G.ok(v, msg)
  if not v then
    error(msg or "expected truthy value", 2)
  end
end

_G.H = dofile(root .. "/tests/helpers.lua")

local specs = vim.fn.globpath(root .. "/tests", "*_spec.lua", false, true)
table.sort(specs)
for _, f in ipairs(specs) do
  local ok, err = pcall(dofile, f)
  if not ok then
    results.fail = results.fail + 1
    table.insert(results.fails, ("%s: <error> %s"):format(vim.fn.fnamemodify(f, ":t"), err))
    io.write("E")
  end
end

io.write("\n")
for _, f in ipairs(results.fails) do
  io.write("\nFAIL  " .. f .. "\n")
end
io.write(("\n%d passed, %d failed, %d skipped\n"):format(results.pass, results.fail, results.skip))
io.flush()

if results.fail > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("quit")
end
