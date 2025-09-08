return {
  name = "Python Run",
  builder = function()
    local cwd = vim.fn.getcwd()
    local file = vim.fn.expand("%")
    return {
      cmd = { "python3" },
      args = { file },
      cwd = cwd,
      components = { { "on_output_quickfix", open = true }, "default" },
    }
  end,
  condition = {
    filetype = { "python" },
  },
}

