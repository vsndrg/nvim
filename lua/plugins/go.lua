-- Go IDE stack:
--   gopls                  — configured in lua/lang/go.lua (build tags, gofumpt,
--                            staticcheck, inlay hints, format+imports on save)
--   golangci-lint          — on-save diagnostics, lua/lang/go_lint.lua
--   go.nvim                — code generation: fill struct/switch, if-err,
--                            struct tags, interface impl, test scaffolding, godoc
--   nvim-dap-go            — delve, with this project's build tags
--   neotest-golang         — test tree/runner (spec lives in lua/plugins/neotest.lua)
--
-- Everything Go-specific is colocated here and in lua/lang/go*.lua. Keymaps are
-- buffer-local via LspAttach and never leak into other filetypes.
--
-- Toolchain (installed with `go install`, deliberately not through mason so the
-- binaries match the active Go toolchain):
--   gopls, dlv, gofumpt, gomodifytags, impl, gotests, iferr

local go_filetypes = { "go", "gomod", "gowork", "gotmpl" }

return {
  ----------------------------------------------------------------------------
  -- 1. go.nvim — code generation and Go-aware editing commands.
  --    `init` runs at startup even though the plugin itself is lazy: gopls must
  --    be registered before the first Go buffer opens.
  ----------------------------------------------------------------------------
  {
    "ray-x/go.nvim",
    dependencies = {
      "ray-x/guihua.lua",
      "neovim/nvim-lspconfig",
      "nvim-treesitter/nvim-treesitter",
    },
    ft = go_filetypes,
    cmd = {
      "GoFillStruct", "GoFillSwitch", "GoIfErr", "GoAddTag", "GoRmTag",
      "GoImpl", "GoAddTest", "GoAddExpTest", "GoDoc", "GoAlt", "GoCoverage",
      "GoModTidy", "GoPkgOutline", "GoGenerate", "GoInstallBinaries",
    },
    init = function()
      require("lang.go").setup()
    end,
    config = function()
      require("go").setup({
        -- gopls belongs to lua/lang/go.lua; go.nvim must not register a second
        -- server config or a competing format-on-save hook.
        lsp_cfg = false,
        lsp_keymaps = false,
        lsp_document_formatting = false,
        lsp_inlay_hints = { enable = false },
        lsp_diag_hdlr = false,
        diagnostic = false,

        -- nvim-dap-go owns delve (build tags, attach picker).
        dap_debug = false,
        dap_debug_gui = false,
        dap_debug_keymap = false,

        gofmt = "gofumpt",
        goimports = "gopls",
        fillstruct = "gopls",
        tag_transform = false,
        test_runner = "go",
        run_in_floaterm = false,
        trouble = false,
        luasnip = true,
        verbose = false,
      })
    end,
  },

  ----------------------------------------------------------------------------
  -- 2. delve. Configured (and re-configured on project switch) from
  --    lang/go.lua:setup_dap so the debugger sees tag-gated test files.
  --    nvim-dap itself is owned by lua/plugins/debug.lua.
  ----------------------------------------------------------------------------
  {
    "leoluz/nvim-dap-go",
    ft = go_filetypes,
    dependencies = { "mfussenegger/nvim-dap" },
    config = function()
      require("lang.go").setup_dap(true)
    end,
  },

  ----------------------------------------------------------------------------
  -- 3. neotest adapter. The neotest core spec is in lua/plugins/neotest.lua,
  --    which pulls adapters from every lang/* module that provides them.
  ----------------------------------------------------------------------------
  {
    "fredrikaverpil/neotest-golang",
    ft = go_filetypes,
    dependencies = { "nvim-neotest/neotest", "leoluz/nvim-dap-go" },
  },
}
