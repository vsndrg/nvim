-- -- ===============
-- -- Auto Commands
-- -- ===============

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "c", "cpp", "java", "rust", "systemverilog" },
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

-- Signature help по Ctrl+k (единственный способ)
-- vim.api.nvim_create_autocmd("LspAttach", {
--   callback = function(args)
--     vim.keymap.set("i", "<C-k>", vim.lsp.buf.signature_help, { buffer = args.buf, silent = true })
--     vim.keymap.set("n", "<C-k>", vim.lsp.buf.signature_help, { buffer = args.buf, silent = true })
--   end,
-- })

vim.api.nvim_create_autocmd("BufEnter", {
  callback = function()
    vim.cmd(":set formatoptions-=ro")
  end
})

-- vim.api.nvim_create_autocmd("VimEnter", {
--   callback = function()
--     vim.cmd("Neotree toggle filesystem left")
--   end
-- })

