return {
  -- REPL client (nREPL)
  {
    "Olical/conjure",
    ft = { "clojure", "clojurescript", "fennel" },
    init = function()
      vim.g["conjure#log#hud#enabled"] = false
      vim.g["conjure#client#clojure#nrepl#connection#auto_repl#enabled"] = true
      vim.g["conjure#client#clojure#nrepl#connection#port_files"] = { ".nrepl-port", os.getenv("HOME") .. "/.lein/repl-port" }
      vim.g["conjure#mapping#doc_word"] = "gk"
    end,
  },

  -- Parinfer: auto-balance parens by indentation
  {
    "gpanders/nvim-parinfer",
    ft = { "clojure", "clojurescript", "fennel", "lisp", "scheme" },
  },

  -- Rainbow delimiters
  {
    "HiPhish/rainbow-delimiters.nvim",
    ft = { "clojure", "clojurescript", "fennel", "lisp", "scheme" },
    config = function()
      require("rainbow-delimiters.setup").setup({
        strategy = { [""] = require("rainbow-delimiters").strategy["global"] },
        query = { [""] = "rainbow-delimiters" },
      })
    end,
  },

  -- Structural editing: slurp / barf / splice / raise
  {
    "guns/vim-sexp",
    ft = { "clojure", "clojurescript", "fennel", "lisp", "scheme" },
    init = function()
      vim.g.sexp_filetypes = "clojure,clojurescript,fennel,lisp,scheme"
      vim.g.sexp_enable_insert_mode_mappings = 0
      vim.g.sexp_mappings = {
        sexp_put_before = { n = "" },
        sexp_put_after = { n = "" },
        sexp_replace = { x = "", n = "" },
        sexp_replace_P = { x = "", n = "" },
        sexp_put_before_op = { n = "" },
        sexp_put_after_op = { n = "" },
        sexp_put_at_head = { n = "" },
        sexp_put_at_tail = { n = "" },
        sexp_replace_op = { n = "" },
        sexp_replace_op_P = { n = "" },
      }
    end,
  },
  {
    "tpope/vim-sexp-mappings-for-regular-people",
    ft = { "clojure", "clojurescript", "fennel", "lisp", "scheme" },
    dependencies = { "guns/vim-sexp", "tpope/vim-repeat" },
  },
}
