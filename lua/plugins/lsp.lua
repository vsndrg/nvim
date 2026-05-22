return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    config = function()
      require("mason").setup()
    end
  },
  {
    "mason-org/mason-lspconfig.nvim",
    lazy = false,
    opts = {
      automatic_enable = false,
      auto_install = true,
      automatic_setup = false,
      ensure_installed = {
        "lua_ls",
        -- clangd: managed by lua/plugins/cpp.lua (prefers Homebrew LLVM clangd).
        -- "jdtls",
        "rust_analyzer",
        "pyright",
        -- "svls",
        "verible",
        "ts_ls",
        "eslint",
        "clojure_lsp",
      }
    }
  },
  {
    "neovim/nvim-lspconfig",
    lazy = false,
    config = function()
      -- LSP capabilities are sourced from blink.cmp when available so servers
      -- get the completion features blink advertises (resolveSupport, etc.).
      local capabilities = vim.lsp.protocol.make_client_capabilities()
      local ok_blink, blink = pcall(require, 'blink.cmp')
      if ok_blink and blink.get_lsp_capabilities then
        capabilities = blink.get_lsp_capabilities(capabilities)
      end
      -- Disable snippet support — LSP returns plain completions without placeholders
      capabilities.textDocument.completion.completionItem.snippetSupport = false

      -- replace deprecated require("lspconfig") usage with a tiny shim that forwards
      -- calls like `lspconfig.NAME.setup(opts)` to the new API `vim.lsp.config/enable`
      local lspconfig = setmetatable({}, {
        __index = function(_, server_name)
          return {
            setup = function(opts)
              vim.lsp.config(server_name, opts)
              vim.lsp.enable(server_name)
            end
          }
        end
      })

      local util = require("lspconfig.util")

      local function get_python_path(workspace)
        if vim.env.VIRTUAL_ENV then
          local active_venv_python = vim.fs.joinpath(vim.env.VIRTUAL_ENV, "bin", "python")
          if vim.fn.executable(active_venv_python) == 1 then
            return active_venv_python
          end
        end

        for _, venv_dir in ipairs({ ".venv", "venv", "env" }) do
          local python = vim.fs.joinpath(workspace, venv_dir, "bin", "python")
          if vim.fn.executable(python) == 1 then
            return python
          end
        end

        if vim.fn.executable("python3") == 1 then
          return vim.fn.exepath("python3")
        end

        return vim.fn.exepath("python")
      end

      lspconfig.lua_ls.setup({
        capabilities = capabilities,
        root_dir = util.root_pattern(".git", ".luarc.json", ".luarc.jsonc", "init.lua"), -- set root
        settings = {
          Lua = {
            runtime = {
              version = 'LuaJIT',
            },
            diagnostics = {
              globals = { 'vim' },
            },
            workspace = {
              library = vim.api.nvim_get_runtime_file("", true),
              checkThirdParty = false,
            },
          },
        }
      })
      -- clangd is set up in lua/lang/cpp.lua (orchestrated by lua/plugins/cpp.lua).

      lspconfig.verible.setup({
        capabilities = capabilities
      })

      -- lspconfig.verible = lspconfig.verible or {}
      -- lspconfig.verible.setup({
      --   cmd = { "verible-verilog-ls" },
      --   filetypes = { "verilog", "systemverilog" },
      --   capabilities = capabilities,
      --   -- optional on_attach: reuse yours if you extract it; otherwise default behaviour
      -- })

      -- lspconfig.jdtls.setup({
      --   capabilities = capabilities
      -- })
      -- lspconfig.pylsp.setup({
      --   capabilities = capabilities,
      --   root_dir = util.root_pattern(".git", "pyproject.toml", "setup.py", "requirements.txt"),
      -- })
      lspconfig.pyright.setup{
        capabilities = capabilities,
        root_markers = { "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile", "pyrightconfig.json", ".git" },
        before_init = function(_, config)
          local workspace = config.root_dir or vim.fn.getcwd()
          config.settings = config.settings or {}
          config.settings.python = config.settings.python or {}
          config.settings.python.pythonPath = get_python_path(workspace)
        end,
        settings = {
          python = {
            analysis = {
              typeCheckingMode = "basic",
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
            }
          }
        }
      }

      lspconfig.ts_ls.setup({
        capabilities = capabilities,
        root_markers = { "package.json", "tsconfig.json", "jsconfig.json", ".git" },
        settings = {
          typescript = { inlayHints = { includeInlayParameterNameHints = "none" } },
          javascript = { inlayHints = { includeInlayParameterNameHints = "none" } },
        },
      })

      lspconfig.eslint.setup({
        capabilities = capabilities,
        root_markers = { "package.json", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json", ".eslintrc.yml", "eslint.config.js", "eslint.config.mjs", ".git" },
        settings = { format = { enable = false } },
      })

      lspconfig.clojure_lsp.setup({
        capabilities = capabilities,
        cmd = { "clojure-lsp" },
        filetypes = { "clojure", "clojurescript", "edn" },
        root_markers = { "project.clj", "deps.edn", "build.boot", "shadow-cljs.edn", ".git" },
        settings = {
          ["clojure-lsp"] = {
            ["source-paths-ignore-regex"] = { "resources/.*", "target/.*" },
          },
        },
      })

      -- rust_analyzer managed by rustaceanvim (lua/plugins/rust.lua)

      vim.diagnostic.config({
        float = { border = "rounded" }
      })

      vim.keymap.set('n', 'K', vim.lsp.buf.hover, {})
      vim.keymap.set('n', 'gd', function()
        vim.lsp.buf.definition({
          on_list = function(options)
            vim.fn.setqflist({}, ' ', options)
            vim.cmd('cfirst')
            vim.cmd('normal! zz')
          end,
        })
      end, {})
      vim.keymap.set('n', 'gr', vim.lsp.buf.references, {})
      vim.keymap.set('n', 'rn', vim.lsp.buf.rename, {})

      vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, {})

      -- Show diagnostics float on demand
      vim.keymap.set('n', 'gl', vim.diagnostic.open_float, {})

      -- Jump diagnostics
      vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, {})
      vim.keymap.set('n', ']d', vim.diagnostic.goto_next, {})

      -- vim.api.nvim_create_autocmd('FileType', {
      --   pattern = 'java',
      --   callback = function()
      --     require('jdtls.jdtls_setup').setup()
      --   end
      -- })

    end
  }
}
