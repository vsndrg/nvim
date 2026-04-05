local M = {}

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function M.format(opts)
  opts = type(opts) == "number" and { bufnr = opts } or (opts or {})
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

  if vim.fn.executable("prettier") ~= 1 then
    vim.notify("prettier is not installed", vim.log.levels.WARN)
    return false
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    vim.notify("Cannot format unnamed buffer with prettier", vim.log.levels.WARN)
    return false
  end

  local input = buf_text(bufnr)
  local cmd = { "prettier", "--stdin-filepath", name }
  if opts.args then
    vim.list_extend(cmd, opts.args)
  end

  local result = vim.system(cmd, { text = true, stdin = input }):wait()

  if result.code ~= 0 then
    local err = (result.stderr or ""):gsub("%s+$", "")
    if err == "" then
      err = "prettier failed"
    end
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end

  local output = result.stdout or ""
  output = output:gsub("\r\n", "\n")
  output = output:gsub("\n$", "")

  if output == input then
    return true
  end

  local view = vim.fn.winsaveview()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(output, "\n", { plain = true }))
  vim.fn.winrestview(view)
  return true
end

return M
