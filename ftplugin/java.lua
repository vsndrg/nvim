vim.bo.shiftwidth = 4
vim.bo.tabstop = 4
vim.bo.expandtab = true

local jdtls = require("jdtls")

local home = os.getenv("HOME")
local project_name = vim.fn.fnamemodify(vim.fn.getcwd(), ":p:h:t")
local workspace_dir = home .. "/.local/share/eclipse/" .. project_name

local capabilities = require("cmp_nvim_lsp").default_capabilities()

local config = {
  cmd = { "jdtls", "-data", workspace_dir },
  root_dir = require("jdtls.setup").find_root({ ".git", "mvnw", "gradlew", "src" }),
  capabilities = capabilities,
}

------------------------------------------------------------------------------

-- local overseer = require("overseer")
--
-- -- Overseer setup with auto window
-- overseer.setup({
--   auto_open = true,
--   auto_open_strategy = "first",
-- })
--
-- -- Compile Java
-- overseer.register_template({
--   name = "Compile Java",
--   builder = function()
--     local file = vim.fn.expand("%")
--     local classdir = vim.fn.getcwd() .. "/bin"
--     return {
--       cmd = { "javac", "-d", classdir, file },
--       cwd = vim.fn.getcwd(),
--     }
--   end,
--   condition = { filetype = { "java" } },
-- })
--
-- -- Run Java
-- overseer.register_template({
--   name = "Run Java",
--   builder = function()
--     local file = vim.fn.expand("%:t:r")
--     local classdir = vim.fn.getcwd() .. "/bin"
--     return {
--       cmd = { "java", "-cp", classdir, file },
--       cwd = vim.fn.getcwd(),
--     }
--   end,
--   condition = { filetype = { "java" } },
-- })


jdtls.start_or_attach(config)
