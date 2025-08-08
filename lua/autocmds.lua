-- -- ===============
-- -- Auto Commands
-- -- ===============

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "c", "cpp", "java", "rust" },
  callback = function()
    -- <expr> mapping: decide at runtime whether to just insert ';' or insert+Esc
    vim.keymap.set("i", ";", function()
      local line  = vim.api.nvim_get_current_line()
      local col   = vim.fn.col(".")         -- 1-based cursor column
      local eol   = #line + 1               -- position just past last char
      if col == eol then
        return ";<Esc>"
      else
        return ";"
      end
    end, { expr = true, noremap = true, buffer = true })
  end,
})

