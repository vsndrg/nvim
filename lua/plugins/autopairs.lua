return {
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",  -- load when you enter insert mode
    opts = {
      check_ts = true,               -- use treesitter to better context-awareness
      disable_filetype = { "TelescopePrompt", "spectre_panel" },
      enable_afterquote = false,     -- don’t pair immediately after quote
    },
    -- or use config if you need to call setup yourself:
    -- config = function(_, opts)
    --   require("nvim-autopairs").setup(opts)
    -- end,
  },
}
