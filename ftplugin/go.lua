-- ftplugin/go.lua — buffer-local options for Go files.
-- All Go LSP keymaps, formatting, linting and tooling are wired in
-- lua/lang/go.lua via an LspAttach autocmd.

-- gofmt indents with hard tabs and rewrites the file on every save, so
-- expandtab would be undone the moment you write. Width 4 only changes how
-- those tabs are rendered.
vim.bo.expandtab = false
vim.bo.tabstop = 4
vim.bo.shiftwidth = 4
vim.bo.softtabstop = 0

vim.bo.commentstring = "// %s"

-- `gq` on a doc comment keeps the leading `// `.
vim.opt_local.comments = "s1:/*,mb:*,ex:*/,://"
