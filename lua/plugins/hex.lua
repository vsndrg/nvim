return {
  {
    "RaafatTurki/hex.nvim",
    config = function()
      require("hex").setup({
        -- CLI command used to dump hex data
        dump_cmd = "xxd -g 1 -u",
        -- CLI command used to assemble from hex data
        assemble_cmd = "xxd -r",
        -- Automatically open binary files in hex mode
        is_file_binary_pre_read = function()
          -- Check file extension
          local binary_ext = { "bin", "exe", "dll", "so", "dylib", "o", "a", "out", "elf", "class", "pyc" }
          local ext = vim.fn.expand("%:e"):lower()
          for _, e in ipairs(binary_ext) do
            if ext == e then return true end
          end
          return false
        end,
        -- Check if buffer content is binary
        is_buf_binary_post_read = function()
          local bufname = vim.api.nvim_buf_get_name(0)
          -- Use 'file' command to detect binary
          local output = vim.fn.system("file --mime-encoding " .. vim.fn.shellescape(bufname))
          return output:match("binary") ~= nil
        end,
      })

      -- Keymaps
      vim.keymap.set("n", "<leader>hx", "<cmd>HexToggle<CR>", { desc = "Toggle hex view" })
      vim.keymap.set("n", "<leader>hd", "<cmd>HexDump<CR>", { desc = "Hex dump" })
      vim.keymap.set("n", "<leader>ha", "<cmd>HexAssemble<CR>", { desc = "Hex assemble (save)" })
    end,
  },
}
