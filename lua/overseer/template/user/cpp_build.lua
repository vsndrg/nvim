return {
  name = "gcc build",
  builder = function()
    -- Full path to current file (see :help expand())
    local file = vim.fn.expand("%:p")
    local out_dir = vim.fn.getcwd() .. "/out"
    local out_file = out_dir .. "/" .. vim.fn.expand("%:t:r")

    -- Make sure output directory exists
    local uv = vim.loop
    if not uv.fs_stat(out_dir) then
      uv.fs_mkdir(out_dir, 493)
    end

    return {
      cmd = { "gcc" },
      args = { file, "-o", out_file },
      components = { { "on_output_quickfix", open = true }, "default" },
    }
  end,
  condition = {
    filetype = { "c" },
  },
}
