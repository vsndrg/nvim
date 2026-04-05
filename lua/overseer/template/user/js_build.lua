return {
  name = "Node Run",
  builder = function()
    return {
      cmd = { "node" },
      args = { vim.fn.expand("%") },
      cwd = vim.fn.getcwd(),
      components = { { "on_output_quickfix", open = true }, "default" },
    }
  end,
  condition = {
    filetype = { "javascript", "typescript" },
  },
}
