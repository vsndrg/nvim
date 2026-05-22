return {
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    config = function()
      require("nvim-autopairs").setup({
        check_ts = true,
        disable_filetype = { "TelescopePrompt", "spectre_panel" },
        enable_afterquote = false,
      })
      -- blink.cmp handles `()` after function-completion via its built-in
      -- completion.accept.auto_brackets — no cmp/autopairs bridge needed.
    end,
  },
}
