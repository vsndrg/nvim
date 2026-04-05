local M = {}

local function has_formatter(bufnr, range)
  local method = range and "textDocument/rangeFormatting" or "textDocument/formatting"
  return #vim.lsp.get_clients({ bufnr = bufnr, method = method }) > 0
end

local function current_range()
  local mode = vim.fn.mode()
  if not mode:match("^[vV\022]") then
    return nil
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  return {
    ["start"] = { start_pos[2] - 1, start_pos[3] - 1 },
    ["end"] = { end_pos[2] - 1, end_pos[3] - 1 },
  }
end

function M.format(opts)
  opts = opts or {}

  local bufnr = vim.api.nvim_get_current_buf()
  local range = opts.range == nil and current_range() or opts.range
  local started = vim.uv.now()
  local timeout_ms = opts.wait_timeout_ms or 1500

  local function try_format()
    if has_formatter(bufnr, range) then
      vim.lsp.buf.format({
        bufnr = bufnr,
        async = false,
        timeout_ms = opts.timeout_ms or 3000,
        range = range,
        filter = opts.filter,
      })
      return
    end

    if vim.uv.now() - started < timeout_ms then
      vim.defer_fn(try_format, 100)
      return
    end

    vim.notify("No formatter attached for this buffer", vim.log.levels.WARN)
  end

  try_format()
end

return M
