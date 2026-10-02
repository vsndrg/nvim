-- neotest core, shared by every language that has a test runner.
--
-- Adapters are contributed by the per-language modules in lua/lang/*.lua: each
-- one exposes `neotest_adapters()` and is listed below. Adding a language means
-- touching that language's file plus this list — never the other languages.
--
-- Buffer-local <leader>t* keymaps are set by the language modules on LspAttach
-- (see lang/cpp.lua and lang/go.lua).

local ADAPTER_PROVIDERS = { "lang.cpp", "lang.go" }

local function adapters()
  local list = {}
  for _, module in ipairs(ADAPTER_PROVIDERS) do
    local ok, lang = pcall(require, module)
    if ok and type(lang.neotest_adapters) == "function" then
      vim.list_extend(list, lang.neotest_adapters())
    end
  end
  return list
end

return {
  {
    "nvim-neotest/neotest",
    ft = { "c", "cpp", "go" },
    dependencies = {
      "nvim-lua/plenary.nvim",
      "antoinemadec/FixCursorHold.nvim",
      "nvim-treesitter/nvim-treesitter",
      "nvim-neotest/nvim-nio",
      "nvim-neotest/neotest-vim-test",
      "vim-test/vim-test",
    },
    config = function()
      require("neotest").setup({
        adapters = adapters(),
        quickfix = { open = false },
        status   = { virtual_text = true, signs = true },
        output   = { open_on_run = false },
        summary  = {
          mappings = {
            run        = "r",
            debug      = "d",
            stop       = "s",
            expand     = { "<CR>", "<2-LeftMouse>" },
            jumpto     = "i",
            output     = "o",
            short      = "O",
            mark       = "m",
            run_marked = "R",
            target     = "t",
          },
        },
      })
    end,
  },
}
