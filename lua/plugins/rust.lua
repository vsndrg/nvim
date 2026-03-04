return {
  {
    "mrcjkb/rustaceanvim",
    version = "^5",
    lazy = false,
    init = function()
      vim.g.rustaceanvim = function()
        local capabilities = require("cmp_nvim_lsp").default_capabilities()
        capabilities.textDocument.completion.completionItem.snippetSupport = false

        local dap_cfg = {}
        local mason_codelldb = vim.fn.stdpath("data") .. "/mason/packages/codelldb/extension/"
        if vim.fn.isdirectory(mason_codelldb) == 1 then
          local codelldb_path = mason_codelldb .. "adapter/codelldb"
          local liblldb_path = mason_codelldb .. "lldb/lib/liblldb"
            .. (vim.fn.has("mac") == 1 and ".dylib" or ".so")
          dap_cfg.adapter = require("rustaceanvim.config").get_codelldb_adapter(
            codelldb_path, liblldb_path
          )
        end

        return {
          server = {
            capabilities = capabilities,
            default_settings = {
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
                inlayHints = {
                  chainingHints = { enable = true },
                  typeHints = { enable = true },
                  parameterHints = { enable = true },
                },
              },
            },
          },
          dap = dap_cfg,
        }
      end
    end,
  },
  {
    "saecki/crates.nvim",
    event = { "BufRead Cargo.toml" },
    config = function()
      local crates = require("crates")
      crates.setup({
        completion = {
          cmp = { enabled = true },
        },
      })

      local function set_keymaps(buf)
        local function map(lhs, rhs, desc)
          vim.keymap.set("n", lhs, rhs, { silent = true, buffer = buf, desc = desc })
        end
        map("<leader>ci", crates.show_popup, "Crate info")
        map("<leader>cv", crates.show_versions_popup, "Crate versions")
        map("<leader>cf", crates.show_features_popup, "Crate features")
        map("<leader>cd", crates.show_dependencies_popup, "Crate dependencies")
        map("<leader>cu", crates.update_crate, "Update crate")
        map("<leader>cU", crates.update_all_crates, "Update all crates")
        map("<leader>cA", crates.upgrade_all_crates, "Upgrade all to latest")
      end

      set_keymaps(0)

      vim.api.nvim_create_autocmd("BufRead", {
        group = vim.api.nvim_create_augroup("CratesKeymaps", { clear = true }),
        pattern = "Cargo.toml",
        callback = function(ev) set_keymaps(ev.buf) end,
      })
    end,
  },
}
