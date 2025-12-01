vim.bo.shiftwidth = 4
vim.bo.tabstop = 4
vim.bo.expandtab = true

local jdtls = require("jdtls")

local home = os.getenv("HOME")

-- Java-specific markers only (NOT .git - it's often in a parent repo)
-- Create .jdtls-root or .project in your Java project root to mark it
local root_markers = { ".jdtls-root", ".project", "pom.xml", "build.gradle", "build.gradle.kts", "mvnw", "gradlew" }
local root_dir = require("jdtls.setup").find_root(root_markers)

-- Fallback: use directory of current file (go up from package dirs)
if not root_dir or root_dir == "" then
  -- Get the file's directory and use it as a starting point
  local fname = vim.api.nvim_buf_get_name(0)
  root_dir = vim.fn.fnamemodify(fname, ":p:h")
end

local project_name = vim.fn.fnamemodify(root_dir, ":p:h:t")
local workspace_dir = home .. "/.local/share/eclipse/" .. project_name

local capabilities = require("cmp_nvim_lsp").default_capabilities()

local config = {
  cmd = { "jdtls", "-data", workspace_dir },
  root_dir = root_dir,
  capabilities = capabilities,
  settings = {
    java = {
      project = {
        -- Source paths relative to root_dir ("." = root is the source folder)
        sourcePaths = { "." },
        -- Use root directory as source folder for simple projects
        referencedLibraries = {},
      },
      -- Import settings for unmanaged (simple) projects
      import = {
        maven = { enabled = false },
        gradle = { enabled = false },
      },
      autobuild = { enabled = true },
    },
  },
}

jdtls.start_or_attach(config)

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


