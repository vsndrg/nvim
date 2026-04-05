vim.bo.expandtab = true
vim.bo.shiftwidth = 4
vim.bo.softtabstop = 4
vim.bo.tabstop = 4

local opts = { buffer = true, silent = true }
local format = require("utils.format").format
local prettier = require("utils.prettier").format
local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", opts, { desc = desc }))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Format
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "<leader>jf", function()
  if not prettier({ args = { "--tab-width", "4", "--use-tabs", "false" } }) then
    format({
      filter = function(client)
        return client.name ~= "eslint"
      end,
    })
  end
end, "Format file")

map("v", "<leader>jf", function()
  if not prettier({ args = { "--tab-width", "4", "--use-tabs", "false" } }) then
    format({
      filter = function(client)
        return client.name ~= "eslint"
      end,
    })
  end
end, "Format file")

-- ═══════════════════════════════════════════════════════════════════════════
-- Code actions (picker — не применяются автоматически)
-- ═══════════════════════════════════════════════════════════════════════════

-- ESLint: показать список доступных eslint-fixes, выбрать вручную
map("n", "<leader>je", function()
  vim.lsp.buf.code_action({ context = { only = { "source.fixAll.eslint" } } })
end, "ESLint fixes (picker)")

-- Organize imports
map("n", "<leader>ji", function()
  vim.lsp.buf.code_action({ context = { only = { "source.organizeImports" } } })
end, "Organize imports (picker)")

-- ═══════════════════════════════════════════════════════════════════════════
-- Rename
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "<leader>jR", function()
  local old_name = vim.fn.expand("%:t")
  vim.ui.input({ prompt = "Rename file to: ", default = old_name }, function(new_name)
    if not new_name or new_name == "" or new_name == old_name then return end
    local old_path = vim.fn.expand("%:p")
    local new_path = vim.fn.expand("%:p:h") .. "/" .. new_name
    vim.lsp.util.rename(old_path, new_path)
  end)
end, "Rename file")
