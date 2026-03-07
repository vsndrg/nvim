return {
  "catppuccin/nvim",
  lazy = false,
  name = "catppuccin",
  priority = 1000,
  config = function()
    require("catppuccin").setup({
      integrations = {
        semantic_tokens = true,
      },
    })
    -- Тема применяется через themery (lua/plugins/themery.lua)
    -- При первом запуске без сохранённой темы — fallback на catppuccin
    local ok = pcall(vim.cmd.colorscheme, "catppuccin")
    if not ok then vim.cmd.colorscheme("default") end
  end
}
