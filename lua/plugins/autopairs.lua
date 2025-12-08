return {
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    config = function()
      local npairs = require("nvim-autopairs")
      npairs.setup({
        check_ts = true,
        disable_filetype = { "TelescopePrompt", "spectre_panel" },
        enable_afterquote = false,
      })

      -- Интеграция с cmp: автоматически добавлять () после выбора функции
      local cmp_autopairs = require("nvim-autopairs.completion.cmp")
      local cmp = require("cmp")
      cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
    end,
  },
}
