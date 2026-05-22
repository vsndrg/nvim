return {
  "folke/noice.nvim",
  event = "VeryLazy",
  opts = {
  },
  dependencies = {
    -- if you lazy-load any plugin below, make sure to add proper `module="..."` entries
    "MunifTanjim/nui.nvim",
    -- OPTIONAL:
    --   `nvim-notify` is only needed, if you want to use the notification view.
    --   If not available, we use `mini` as the fallback
    {
      "rcarriga/nvim-notify",
      opts = function()
        -- Resolve Normal's bg so notify's transparency compositing has a real
        -- colour to work with. Falls back to a dark hex when Normal has no bg
        -- (e.g. fully transparent themes) — otherwise notify emits a warning
        -- on the first notification because the default "NotifyBackground"
        -- highlight group has no bg under most colorschemes.
        local function normal_bg()
          local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
          if ok and hl and hl.bg then
            return string.format("#%06x", hl.bg)
          end
          return "#1e1e2e"
        end
        return { background_colour = normal_bg() }
      end,
    },
  },
  config = function()
    require("noice").setup({
      presets = {
        bottom_search = false,
        command_palette = true,
        lsp_doc_border = true,
      },
      routes = {
        {
          filter = {
            event = "msg_show",
            kind = "",
            find = "written",
          },
          opts = { skip = true },
        },
      },
      lsp = {
        progress = {
          enabled = false,
        },
      },
    })
    vim.keymap.set("n", "<leader>dm", ":NoiceDismiss<CR>", { silent = true })
  end
}
