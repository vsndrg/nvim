return {
  "OXY2DEV/markview.nvim",
  lazy = false,
  opts = {
    preview = {
      icon_provider = "mini",
      hybrid_modes = { "n", "i" },
    },
  },
  config = function(_, opts)
    require("markview").setup(opts)

    -- Markview schedules render/clear callbacks via a debounce timer in
    -- autocmds.lua. When sessions are switched (or buffers are wiped for any
    -- other reason) between scheduling and execution, the callback runs against
    -- a buffer that no longer exists and nvim_buf_clear_namespace errors out.
    -- Guard the entry points so invalid buffers are silently skipped.
    local actions = require("markview.actions")

    local function guard(name)
      local orig = actions[name]
      actions[name] = function(buffer, ...)
        local buf = buffer or vim.api.nvim_get_current_buf()
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        return orig(buffer, ...)
      end
    end

    guard("render")
    guard("clear")
  end,
}
