return {
  name = "Cargo Build",
  builder = function()
    local cwd = vim.fn.getcwd()
    return {
      cmd = { "cargo" },
      args = { "build" },
      cwd = cwd,
      components = { { "on_output_quickfix", open = true }, "default" },
    }
  end,
  condition = {
    filetype = { "rust" },
  },
}

