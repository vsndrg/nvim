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
        "clangd",
        -- "jdtls",
        "rust_analyzer",
        "pyright",
        "svls",
        "verible",
      }
    }
  },
  {
    "mfussenegger/nvim-jdtls",
    ft = "java"
  },
  {
    "neovim/nvim-lspconfig",
    lazy = false,
    config = function()
      local capabilities = require('cmp_nvim_lsp').default_capabilities()

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
      lspconfig.clangd.setup({
        capabilities = capabilities
      })

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
        -- on_attach = on_attach,
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

      local rust_opts = {
        capabilities = capabilities,
        root_dir = util.root_pattern("Cargo.toml", "rust-project.json", ".git"),
        settings = {
          ["rust-analyzer"] = {
            cargo = {
              allFeatures = true,
              loadOutDirsFromCheck = true,
              runBuildScripts = true,
            },
            check = {
              command = "clippy",
              allTargets = true,
            },
            procMacro = {
              enable = true,
            },
          },
        },
      }

      -- If you use rust-tools or another plugin that auto-configures rust-analyzer,
      -- let it own the setup to avoid starting two servers. Otherwise fall back to lspconfig.
      local ok, rt = pcall(require, "rust-tools")
      if ok and rt.setup then
        rt.setup({ server = rust_opts })
      else
        lspconfig.rust_analyzer.setup(rust_opts)
      end

      vim.diagnostic.config({
        float = { border = "rounded" }
      })

      vim.keymap.set('n', 'K', vim.lsp.buf.hover, {})
      vim.keymap.set('n', 'gd', vim.lsp.buf.definition, {})
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

