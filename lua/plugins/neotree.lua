return {
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-tree/nvim-web-devicons",
  },
  lazy = false,
  config = function()
    require("neo-tree").setup({
      -- close Neo-tree when it's the last window left
      -- close_if_last_window = true,

      filesystem = {
        -- show all hidden files and dotfiles
        filtered_items = {
          visible = true,
          hide_dotfiles = false,
          hide_gitignored = false,
          hide_hidden = false,
        },

        follow_current_file = {
          enabled = true,
          leave_dirs_open = true,
        },

        use_libuv_file_watcher = true
      },

      buffers = {
        follow_current_file = {
          enabled = true,
          leave_dirs_open = true,
        },
      },

      default_component_configs = {
        -- no need to set modified: Neo-tree shows unsaved buffers by default
        -- to customize, you can override the symbol here
      },

      window = {
        mapping_options = {
          noremap = true,
          nowait = true,
        },
        mappings = {
          ["l"] = "open",
          ["L"] = "open_vsplit",
          ["<A-l>"] = "open_split",
          ["h"] = "close_node",
        },
      },
    })

    -- toggle Neo-tree with <leader>n
    vim.keymap.set("n", "<leader>n", ":Neotree toggle filesystem left<CR>", { noremap = true, silent = true })
  end
}
