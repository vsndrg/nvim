return {
  "stevearc/overseer.nvim",
  config = function()
    require("overseer").setup({
      templates = { "user.cpp_build", "user.c_build", "user.rust_build"  },
    })

    vim.keymap.set('n', "<leader>b", ":OverseerRun<CR>", {})
  end
}

