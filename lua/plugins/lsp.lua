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

      -- helper: make root_dir function that searches upward from the buffer file
      local function make_root_dir(...)
        local patterns = { ... }
        return function(fname)
          fname = fname or vim.api.nvim_buf_get_name(0)
          if fname == "" then
            return vim.loop.cwd()
          end
          local start_dir = vim.fs.dirname(fname)
          for _, p in ipairs(patterns) do
            local found = vim.fs.find(p, { path = start_dir, upward = true })
            if found and #found > 0 then
              return vim.fs.dirname(found[1])
            end
          end
          return vim.loop.cwd()
        end
      end

      -- lua_ls
      vim.lsp.config('lua_ls', {
        capabilities = capabilities,
        root_dir = make_root_dir(".git", ".luarc.json", ".luarc.jsonc", "init.lua"),
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
      vim.lsp.enable('lua_ls')

      -- clangd
      vim.lsp.config('clangd', {
        capabilities = capabilities,
        root_dir = make_root_dir(".git"),
      })
      vim.lsp.enable('clangd')

      -- verible (verilog/systemverilog)
      vim.lsp.config('verible', {
        capabilities = capabilities,
        root_dir = make_root_dir(".git"),
      })
      vim.lsp.enable('verible')

      -- pyright
      vim.lsp.config('pyright', {
        capabilities = capabilities,
        root_dir = make_root_dir(".git", "pyproject.toml", "setup.py", "requirements.txt"),
        settings = {
          python = {
            analysis = {
              typeCheckingMode = "basic",
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
            }
          }
        }
      })
      vim.lsp.enable('pyright')

      -- rust_analyzer: allow rust-tools to take ownership if present
      local rust_opts = {
        capabilities = capabilities,
        root_dir = make_root_dir("Cargo.toml", "rust-project.json", ".git"),
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

      local ok, rt = pcall(require, "rust-tools")
      if ok and rt.setup then
        rt.setup({ server = rust_opts })
      else
        vim.lsp.config('rust_analyzer', rust_opts)
        vim.lsp.enable('rust_analyzer')
      end

      -- diagnostics visual config
      vim.diagnostic.config({
        float = { border = "rounded" }
      })

      -- keymaps
      vim.keymap.set('n', 'K', vim.lsp.buf.hover, {})
      vim.keymap.set('n', 'gd', vim.lsp.buf.definition, {})
      vim.keymap.set('n', 'gr', vim.lsp.buf.references, {})
      vim.keymap.set('n', 'rn', vim.lsp.buf.rename, {})
      vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, {})
      vim.keymap.set('n', 'gl', vim.diagnostic.open_float, {})
      vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, {})
      vim.keymap.set('n', ']d', vim.diagnostic.goto_next, {})

      -- Note: jdtls handled by mfussenegger/nvim-jdtls plugin (ft=java). If you want to
      -- use vim.lsp.config for jdtls as well, you can add a config block similar to above.

    end
  }
}

