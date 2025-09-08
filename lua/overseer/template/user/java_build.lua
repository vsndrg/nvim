return {
  name = "java build & run",
  builder = function()
    local file = vim.fn.expand("%:p")
    local out_dir = vim.fn.getcwd() .. "/bin"
    local uv = vim.loop

    -- ensure out dir exists
    if not uv.fs_stat(out_dir) then
      uv.fs_mkdir(out_dir, 493) -- 0755
    end

    -- class name (без пакета)
    local class = vim.fn.expand("%:t:r")

    -- compile && run in one shell command (run only if javac exit code == 0)
    local cmd = string.format(
      "javac -d %s %s && java -cp %s %s",
      vim.fn.shellescape(out_dir),
      vim.fn.shellescape(file),
      vim.fn.shellescape(out_dir),
      vim.fn.shellescape(class)
    )

    return {
      -- run via shell so && works
      cmd = { "sh", "-c", cmd },
      -- open quickfix / overseer window as before
      components = {
        { "on_output_quickfix", open = true },
        "on_exit_set_status",
      }
    }
  end,
  condition = {
    filetype = { "java" },
  },
}

