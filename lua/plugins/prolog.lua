-- Prolog (tuProlog 4.0) plugin spec.
--
-- Архитектура:
--   * lua/prolog/repl.lua  — управление Java-subprocess'ом TuPrologRepl
--   * lua/prolog/ide.lua   — 3-pane IDE layout (editor / query / output)
--   * lua/prolog/repl/TuPrologRepl.java — тонкая stateful обёртка над alice.tuprolog API
--   * ftplugin/prolog.lua  — buffer-local настройки и keymaps
--   * snippets/prolog.json — typical Prolog-конструкции
--
-- LSP не подключаем: swipl-lsp не понимает tuProlog-диалект.

return {
  -- Rainbow delimiters для Prolog-скобок.
  {
    "HiPhish/rainbow-delimiters.nvim",
    ft = { "prolog" },
  },

  -- Регистрируем :PrologIDE и пользовательскую команду на «локальный» fake-плагин,
  -- который lazy.nvim нормально игнорирует (dir = config root, ft-trigger).
  {
    dir = vim.fn.stdpath("config"),
    name = "prolog-ide-cmd",
    ft = { "prolog" },
    config = function()
      vim.api.nvim_create_user_command("PrologIDE", function()
        require("prolog.ide").open()
      end, { desc = "Open tuProlog 3-pane IDE" })

      vim.api.nvim_create_user_command("PrologRestart", function()
        require("prolog.ide").restart()
      end, { desc = "Restart tuProlog REPL" })

      vim.api.nvim_create_user_command("PrologStop", function()
        require("prolog.repl").stop()
      end, { desc = "Stop tuProlog REPL" })
    end,
  },
}
