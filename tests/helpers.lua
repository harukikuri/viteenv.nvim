-- tests/helpers.lua — small utilities for the specs (returned as a table,
-- exposed to specs as the global `H` by run.lua).

local H = {}

--- Create a scratch buffer with the given lines + filetype, make it current.
---@param lines string[]
---@param ft string|nil
---@return integer bufnr
function H.make_buf(lines, ft)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  if ft then
    vim.bo[b].filetype = ft
  end
  vim.api.nvim_set_current_buf(b)
  return b
end

--- vim.wait wrapper.
function H.wait(pred, timeout)
  return vim.wait(timeout or 5000, pred, 20)
end

--- Is a Treesitter parser for `lang` loadable?
function H.has_parser(lang)
  return (pcall(vim.treesitter.language.add, lang))
end

function H.node_available()
  return vim.fn.executable("node") == 1
end

function H.repo_root()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
end

function H.example_app()
  return H.repo_root() .. "/examples/react-app"
end

--- Is the example app usable (node + its vite installed)?
function H.example_ready()
  return H.node_available() and vim.uv.fs_stat(H.example_app() .. "/node_modules/vite") ~= nil
end

function H.tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

function H.write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

--- Normalize a path for comparison (resolve symlinks like /var -> /private/var).
function H.norm(path)
  return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/$", ""))
end

return H
