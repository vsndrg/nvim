-- C/C++ IDE-level stack:
--   clangd (LSP)                 — configured in lua/lang/cpp.lua
--   clangd_extensions.nvim       — AST view, symbol info, memory usage
--   cmake-tools.nvim             — configure/build/run/debug targets, kits, build types
--   conform.nvim                 — clang-format with .clang-format detection
--   neotest + neotest-vim-test   — universal test runner (Catch2 by default);
--                                  core spec in lua/plugins/neotest.lua
--   nvim-dap config              — wired to cmake-tools launch target
--
-- All C++ specifics are colocated here. Keymaps are buffer-local via LspAttach
-- and won't leak into other languages.

local cpp = function() return require("lang.cpp") end

return {
  ----------------------------------------------------------------------------
  -- 1. Core C/C++ orchestration. Registers clangd server config and the
  --    LspAttach autocmd that wires up buffer-local keymaps.
  --    Runs at startup (eager) since vim.lsp.enable must be called before
  --    any C/C++ file is opened.
  ----------------------------------------------------------------------------
  {
    "p00f/clangd_extensions.nvim",
    lazy = false,
    priority = 100,
    dependencies = {
      "neovim/nvim-lspconfig",
    },
    config = function()
      require("clangd_extensions").setup({
        ast = {
          role_icons = {
            type = "🄣",
            declaration = "🄓",
            expression = "🄔",
            statement = ";",
            specifier = "🄢",
            ["template argument"] = "🆃",
          },
          kind_icons = {
            Compound = "🄲",
            Recovery = "🅁",
            TranslationUnit = "🅄",
            PackExpansion = "🄿",
            TemplateTypeParm = "🅃",
            TemplateTemplateParm = "🅃",
            TemplateParamObject = "🅃",
          },
          highlights = { detail = "Comment" },
        },
        memory_usage = { border = "rounded" },
        symbol_info  = { border = "rounded" },
      })

      cpp().setup()
    end,
  },

  ----------------------------------------------------------------------------
  -- 2. CMake integration. Separate build dirs per build type (Debug/Release).
  ----------------------------------------------------------------------------
  {
    "Civitasv/cmake-tools.nvim",
    ft = { "c", "cpp", "cmake" },
    cmd = {
      "CMakeGenerate", "CMakeBuild", "CMakeRun", "CMakeDebug",
      "CMakeSelectBuildTarget", "CMakeSelectLaunchTarget",
      "CMakeSelectBuildType", "CMakeSelectKit",
      "CMakeQuickBuild", "CMakeQuickRun", "CMakeQuickDebug",
      "CMakeClean", "CMakeStop",
    },
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      require("cmake-tools").setup({
        cmake_command = "cmake",
        ctest_command = "ctest",
        cmake_regenerate_on_save = true,
        cmake_generate_options = {
          "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
        },
        cmake_build_options = {},
        -- Separate build dirs per build type; clangd reads compile_commands.json
        -- via the symlink cmake-tools maintains at the project root.
        cmake_build_directory = "build/${variant:buildType}",
        cmake_soft_link_compile_commands = true,
        cmake_compile_commands_from_lsp = false,
        cmake_kits_path = nil,
        cmake_variants_message = {
          short = { show = true },
          long  = { show = true, max_length = 40 },
        },
        cmake_dap_configuration = {
          name = "cpp (cmake-tools)",
          type = "codelldb",
          request = "launch",
          stopOnEntry = false,
          runInTerminal = false,
          console = "integratedTerminal",
        },
        cmake_executor = {
          name = "quickfix",
          opts = {},
          default_opts = {
            quickfix = {
              show = "always",
              position = "belowright",
              size = 10,
              encoding = "utf-8",
              auto_close_when_success = true,
            },
          },
        },
        cmake_runner = {
          name = "terminal",
          opts = {},
          default_opts = {
            terminal = {
              name = "Main Terminal",
              prefix_name = "[CMakeTools]: ",
              split_direction = "horizontal",
              split_size = 11,
              single_terminal_per_instance = true,
              single_terminal_per_tab = true,
              keep_terminal_static_location = true,
              start_insert = false,
              focus = false,
              do_not_add_newline = false,
            },
          },
        },
        cmake_notifications = {
          runner = { enabled = true },
          executor = { enabled = true },
          spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
          refresh_rate_ms = 100,
        },
        cmake_virtual_text_support = true,
      })

      cpp().setup_cmake_keymaps()
    end,
  },

  ----------------------------------------------------------------------------
  -- 3. Formatter (clang-format). format-on-save is gated by .clang-format
  --    presence + per-buffer toggle (see lang/cpp.lua).
  ----------------------------------------------------------------------------
  {
    "stevearc/conform.nvim",
    ft = { "c", "cpp", "objc", "objcpp", "cuda" },
    config = function()
      require("conform").setup({
        formatters_by_ft = {
          c      = { "clang_format" },
          cpp    = { "clang_format" },
          objc   = { "clang_format" },
          objcpp = { "clang_format" },
          cuda   = { "clang_format" },
        },
        formatters = {
          clang_format = {
            command = require("lang.cpp").clang_format(),
            -- --style=file uses project .clang-format; LLVM fallback when missing,
            -- so manual <leader>cf always works (format-on-save still gated separately).
            prepend_args = { "--style=file", "--fallback-style=LLVM" },
          },
        },
      })
    end,
  },

  -- Note: the neotest plugin spec moved to lua/plugins/neotest.lua once Go
  -- joined it — the core is shared and each language contributes adapters
  -- through its own `neotest_adapters()` (lang/cpp.lua, lang/go.lua).
  -- C/C++ adapters are still defined in lang/cpp.lua; nothing else changed.
  --
  -- Note: C/C++ keyword completion comes from lua/lang/cpp_keywords.lua
  -- (a native blink.cmp source). Signature help is owned by noice.nvim.
  --
  -- Note: nvim-dap C/C++ configuration is registered from lang/cpp.lua via
  -- a FileType autocmd (see setup_autocmds). nvim-dap itself is owned by
  -- lua/plugins/debug.lua to keep one source of truth for the plugin spec.
}
