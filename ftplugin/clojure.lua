-- Buffer-local settings & keymaps for Clojure files.

vim.bo.expandtab   = true
vim.bo.shiftwidth  = 2
vim.bo.softtabstop = 2
vim.bo.tabstop     = 2


-- Format on save via clojure-lsp (cljfmt under the hood).
vim.api.nvim_create_autocmd("BufWritePre", {
  buffer = 0,
  callback = function()
    vim.lsp.buf.format({ async = false, timeout_ms = 3000 })
  end,
})

local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = true, silent = true, desc = desc })
end

map({ "n", "v" }, "<leader>vf", function() vim.lsp.buf.format({ async = true }) end, "Format")

-- nREPL connection (auto-connect handles the common case via .nrepl-port).
map("n", "<leader>vc", "<cmd>ConjureConnect<CR>",    "Conjure: connect")
map("n", "<leader>vd", "<cmd>ConjureDisconnect<CR>", "Conjure: disconnect")

-- Unified eval: in normal mode evaluates the root form (the top-level
-- defn/def around the cursor), in visual mode evaluates the selection.
-- Implemented by replaying Conjure's own mappings (,er and ,E) so behaviour
-- stays consistent with the rest of Conjure even if it changes upstream.
local function feed_local(keys)
  local resolved = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(resolved, "m", false)
end

map("n", "<leader>e", function() feed_local("<localleader>er") end, "Eval root form")
map("x", "<leader>e", function() feed_local("<localleader>E")  end, "Eval selection")
map("n", "<leader>E", function() feed_local("<localleader>ef") end, "Eval file")

-- vim-sexp wrap: no-insert variants under doubled localleader.
--
-- Default ,w / ,i / ,[ / ,{ etc. wrap and drop into insert mode after
-- (g:sexp_insert_after_wrap = 1, set in plugins/clojure.lua). The
-- corresponding ,,w / ,,i / ,,[ / ,,{ etc. wrap and stay in normal mode,
-- handy when you just want to add brackets without typing further.
--
-- Letter (X) meaning, mirrors vim-sexp defaults:
--   w / W   element (word) in (), cursor at head / tail
--   i / I   form (list)    in (), cursor at head / tail
--   [ / ]   form           in [], cursor at head / tail
--   { / }   form           in {}, cursor at head / tail
local wrap_specs = {
  -- key, type ('e'=element, 'f'=form), left, right, pos (0=head, 1=tail)
  { "w", "e", "(", ")", 0 },
  { "W", "e", "(", ")", 1 },
  { "i", "f", "(", ")", 0 },
  { "I", "f", "(", ")", 1 },
  { "[", "f", "[", "]", 0 },
  { "]", "f", "[", "]", 1 },
  { "{", "f", "{", "}", 0 },
  { "}", "f", "{", "}", 1 },
}

for _, spec in ipairs(wrap_specs) do
  local key, typ, left, right, pos = spec[1], spec[2], spec[3], spec[4], spec[5]
  local what  = typ == "e" and "element" or "form"
  local where = pos == 1 and "tail" or "head"
  local desc  = ("Wrap %s in %s%s — cursor %s, no insert"):format(what, left, right, where)
  map("n", "<localleader><localleader>" .. key, function()
    vim.fn["sexp#wrap"](typ, left, right, pos, 0)
  end, desc)
end

-- Smart go-to-definition.
-- clojure-lsp resolves what it can see statically (ns/require, source-paths).
-- For symbols introduced via (load-file ...) it has no answer, so fall back to
-- Conjure's REPL-driven lookup, which knows the live state of the nREPL.
map("n", "gd", function()
  local params = vim.lsp.util.make_position_params(0, "utf-8")
  vim.lsp.buf_request(0, "textDocument/definition", params, function(err, result)
    if not err and result and not vim.tbl_isempty(result) then
      local target = vim.islist(result) and result[1] or result
      vim.lsp.util.show_document(target, "utf-8", { focus = true })
    else
      local keys = vim.api.nvim_replace_termcodes("<localleader>gd", true, false, true)
      vim.api.nvim_feedkeys(keys, "m", false)
    end
  end)
end, "Go to definition (LSP -> Conjure REPL)")
