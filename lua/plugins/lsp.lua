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
      auto_install = true,
      automatic_setup = false,
      ensure_installed = {
        "lua_ls",
        "clangd",
        "jdtls",
        "rust_analyzer",
      }
    }
  },
  {
    "neovim/nvim-lspconfig",
    lazy = false,
    config = function()
      local capabilities = require('cmp_nvim_lsp').default_capabilities()
      local lspconfig = require("lspconfig")
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
      lspconfig.jdtls.setup({
        capabilities = capabilities
      })

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
      vim.keymap.set('n', 'rn', vim.lsp.buf.rename, {})

      vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, {})

      -- Show diagnostics float on demand
      vim.keymap.set('n', 'gl', vim.diagnostic.open_float, {})

      -- Jump diagnostics
      vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, {})
      vim.keymap.set('n', ']d', vim.diagnostic.goto_next, {})

    end
  }
}
