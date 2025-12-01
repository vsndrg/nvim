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

-- Extended capabilities for code action support
local extendedClientCapabilities = jdtls.extendedClientCapabilities
extendedClientCapabilities.resolveAdditionalTextEditsSupport = true

------------------------------------------------------------------------------
-- Debug & Test bundles (install via Mason: java-debug-adapter, java-test)
------------------------------------------------------------------------------
local bundles = {}
local mason_path = vim.fn.stdpath("data") .. "/mason/packages"

-- java-debug-adapter
local java_debug_path = mason_path .. "/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar"
local java_debug_bundle = vim.fn.glob(java_debug_path, true)
if java_debug_bundle ~= "" then
  table.insert(bundles, java_debug_bundle)
end

-- java-test (for running JUnit tests)
local java_test_path = mason_path .. "/java-test/extension/server/*.jar"
local java_test_bundles = vim.split(vim.fn.glob(java_test_path, true), "\n")
if java_test_bundles[1] ~= "" then
  vim.list_extend(bundles, java_test_bundles)
end

local config = {
  cmd = { "jdtls", "-data", workspace_dir },
  root_dir = root_dir,
  capabilities = capabilities,

  -- Callback when jdtls attaches - setup DAP
  on_attach = function(client, bufnr)
    -- Enable debugging
    if #bundles > 0 then
      jdtls.setup_dap({ hotcodereplace = "auto" })
      -- Setup dap main class configs
      require("jdtls.dap").setup_dap_main_class_configs()
    end
  end,

  settings = {
    java = {
      project = {
        sourcePaths = { "." },
        referencedLibraries = {},
      },
      -- Signature help (shows method parameters as you type)
      signatureHelp = { enabled = true },
      -- Content assist (auto-completion)
      contentProvider = { preferred = "fernflower" }, -- better decompiler
      completion = {
        favoriteStaticMembers = {
          "org.junit.Assert.*",
          "org.junit.jupiter.api.Assertions.*",
          "org.mockito.Mockito.*",
          "java.util.Objects.requireNonNull",
          "java.util.Objects.requireNonNullElse",
        },
        importOrder = { "java", "javax", "com", "org" },
        filteredTypes = {
          "com.sun.*",
          "io.micrometer.shaded.*",
          "java.awt.*",
          "jdk.*",
          "sun.*",
        },
      },
      -- Sources & formatting
      sources = {
        organizeImports = {
          starThreshold = 9999,
          staticStarThreshold = 9999,
        },
      },
      -- Code generation settings (like IntelliJ)
      codeGeneration = {
        toString = {
          template = "${object.className}{${member.name()}=${member.value}, ${otherMembers}}",
        },
        useBlocks = true,
        hashCodeEquals = {
          useJava7Objects = true,
          useInstanceof = true,
        },
        generateComments = false,
      },
      -- Import settings
      import = {
        maven = { enabled = true },
        gradle = { enabled = true },
      },
      autobuild = { enabled = true },
      -- Inlay hints (parameter names, like IntelliJ)
      inlayHints = {
        parameterNames = { enabled = "all" },
      },
    },
  },

  init_options = {
    extendedClientCapabilities = extendedClientCapabilities,
    bundles = bundles,
  },
}

jdtls.start_or_attach(config)

------------------------------------------------------------------------------
-- Java-specific keymaps (IntelliJ-like)
-- These only work in Java buffers (buffer = true)
------------------------------------------------------------------------------
local opts = { buffer = true, silent = true }

-- ═══════════════════════════════════════════════════════════════════════════
-- EXTRACT/REFACTOR (<leader>e...)
-- ═══════════════════════════════════════════════════════════════════════════

-- Extract variable (IntelliJ: Ctrl+Alt+V)
vim.keymap.set("n", "<leader>ev", jdtls.extract_variable, vim.tbl_extend("force", opts, { desc = "Extract variable" }))
vim.keymap.set("v", "<leader>ev", function() jdtls.extract_variable(true) end, vim.tbl_extend("force", opts, { desc = "Extract variable" }))

-- Extract constant (IntelliJ: Ctrl+Alt+C)
vim.keymap.set("n", "<leader>ec", jdtls.extract_constant, vim.tbl_extend("force", opts, { desc = "Extract constant" }))
vim.keymap.set("v", "<leader>ec", function() jdtls.extract_constant(true) end, vim.tbl_extend("force", opts, { desc = "Extract constant" }))

-- Extract method (IntelliJ: Ctrl+Alt+M) - visual mode only
vim.keymap.set("v", "<leader>em", function() jdtls.extract_method(true) end, vim.tbl_extend("force", opts, { desc = "Extract method" }))

-- Inline variable/method (IntelliJ: Ctrl+Alt+N) - opposite of extract
vim.keymap.set("n", "<leader>ei", function()
  vim.lsp.buf.code_action({
    context = { only = { "refactor.inline" } },
  })
end, vim.tbl_extend("force", opts, { desc = "Inline variable/method" }))

-- ═══════════════════════════════════════════════════════════════════════════
-- ORGANIZE (<leader>o...)
-- ═══════════════════════════════════════════════════════════════════════════

-- Organize imports (IntelliJ: Ctrl+Alt+O)
vim.keymap.set("n", "<leader>io", jdtls.organize_imports, vim.tbl_extend("force", opts, { desc = "Organize imports" }))

-- ═══════════════════════════════════════════════════════════════════════════
-- NAVIGATION (g...)
-- ═══════════════════════════════════════════════════════════════════════════

-- Show implementations (IntelliJ: Ctrl+Alt+B)
vim.keymap.set("n", "gI", vim.lsp.buf.implementation, vim.tbl_extend("force", opts, { desc = "Go to implementations" }))

-- Go to super implementation (IntelliJ: Ctrl+U)
vim.keymap.set("n", "gS", function()
  require("jdtls").super_implementation()
end, vim.tbl_extend("force", opts, { desc = "Go to super" }))

-- Type hierarchy (IntelliJ: Ctrl+H) - use LSP built-in
vim.keymap.set("n", "gH", vim.lsp.buf.typehierarchy, vim.tbl_extend("force", opts, { desc = "Type hierarchy" }))

-- ═══════════════════════════════════════════════════════════════════════════
-- GENERATE (<leader>g...)
-- ═══════════════════════════════════════════════════════════════════════════

-- Generate code menu (constructor, getters/setters, equals/hashCode, toString)
vim.keymap.set("n", "<leader>gc", function()
  vim.lsp.buf.code_action({
    context = { only = { "source.generate" } },
  })
end, vim.tbl_extend("force", opts, { desc = "Generate code" }))

-- ═══════════════════════════════════════════════════════════════════════════
-- UNIT TESTS (<leader>u...)
-- ═══════════════════════════════════════════════════════════════════════════

-- Test nearest method (IntelliJ: green play button) - requires java-test
vim.keymap.set("n", "<leader>ut", function()
  require("jdtls.dap").test_nearest_method()
end, vim.tbl_extend("force", opts, { desc = "Test nearest method" }))

-- Test entire class - requires java-test
vim.keymap.set("n", "<leader>uT", function()
  require("jdtls.dap").test_class()
end, vim.tbl_extend("force", opts, { desc = "Test class" }))

-- Pick test to run (requires java-test)
vim.keymap.set("n", "<leader>up", function()
  require("jdtls.dap").pick_test()
end, vim.tbl_extend("force", opts, { desc = "Pick test" }))

-- Debug test (runs with debugger attached) - requires java-test & java-debug
vim.keymap.set("n", "<leader>ud", function()
  require("jdtls.dap").test_nearest_method()
end, vim.tbl_extend("force", opts, { desc = "Debug test" }))

-- ═══════════════════════════════════════════════════════════════════════════
-- PROJECT (<leader>p...)
-- ═══════════════════════════════════════════════════════════════════════════

-- Update project configuration (after changing pom.xml/build.gradle)
vim.keymap.set("n", "<leader>pu", function()
  require("jdtls").update_projects_config()
  print("Project configuration updated")
end, vim.tbl_extend("force", opts, { desc = "Update project config" }))

-- ═══════════════════════════════════════════════════════════════════════════
-- CREATE NEW CLASS (<leader>n...)
-- ═══════════════════════════════════════════════════════════════════════════

-- Helper: determine package name from directory path relative to root
local function get_package_from_path(file_dir)
  -- Get relative path from root_dir
  local rel_path = file_dir:gsub("^" .. vim.pesc(root_dir) .. "/?", "")
  -- Convert path separators to dots (package notation)
  local package = rel_path:gsub("/", ".")
  -- Remove leading/trailing dots
  package = package:gsub("^%.+", ""):gsub("%.+$", "")
  return package
end

-- Create new Java class
local function create_java_class(class_type)
  class_type = class_type or "class"
  
  -- Get current buffer's directory or use root_dir
  local current_file = vim.api.nvim_buf_get_name(0)
  local current_dir = current_file ~= "" and vim.fn.fnamemodify(current_file, ":p:h") or root_dir
  
  -- Ask for class name
  vim.ui.input({ prompt = "Class name: " }, function(class_name)
    if not class_name or class_name == "" then
      return
    end
    
    -- Validate class name (must start with uppercase, alphanumeric)
    if not class_name:match("^%u[%w]*$") then
      vim.notify("Invalid class name. Must start with uppercase letter.", vim.log.levels.ERROR)
      return
    end
    
    -- Ask for subdirectory (package path) - optional
    vim.ui.input({ 
      prompt = "Package subdirectory (relative to current dir, empty for current): ",
      default = ""
    }, function(subdir)
      local target_dir = current_dir
      if subdir and subdir ~= "" then
        target_dir = current_dir .. "/" .. subdir
        -- Create directory if it doesn't exist
        vim.fn.mkdir(target_dir, "p")
      end
      
      local package_name = get_package_from_path(target_dir)
      local file_path = target_dir .. "/" .. class_name .. ".java"
      
      -- Check if file already exists
      if vim.fn.filereadable(file_path) == 1 then
        vim.notify("File already exists: " .. file_path, vim.log.levels.ERROR)
        return
      end
      
      -- Generate class template
      local lines = {}
      if package_name ~= "" then
        table.insert(lines, "package " .. package_name .. ";")
        table.insert(lines, "")
      end
      
      if class_type == "class" then
        table.insert(lines, "public class " .. class_name .. " {")
        table.insert(lines, "    ")
        table.insert(lines, "}")
      elseif class_type == "interface" then
        table.insert(lines, "public interface " .. class_name .. " {")
        table.insert(lines, "    ")
        table.insert(lines, "}")
      elseif class_type == "enum" then
        table.insert(lines, "public enum " .. class_name .. " {")
        table.insert(lines, "    ")
        table.insert(lines, "}")
      elseif class_type == "record" then
        table.insert(lines, "public record " .. class_name .. "() {")
        table.insert(lines, "    ")
        table.insert(lines, "}")
      end
      
      -- Write file
      vim.fn.writefile(lines, file_path)
      
      -- Open the new file
      vim.cmd("edit " .. file_path)
      
      -- Position cursor inside the class body
      local cursor_line = package_name ~= "" and 4 or 2
      vim.api.nvim_win_set_cursor(0, { cursor_line, 4 })
      
      vim.notify("Created: " .. file_path, vim.log.levels.INFO)
    end)
  end)
end

-- New class
vim.keymap.set("n", "<leader>cc", function()
  create_java_class("class")
end, vim.tbl_extend("force", opts, { desc = "New Java class" }))

-- New interface
vim.keymap.set("n", "<leader>ci", function()
  create_java_class("interface")
end, vim.tbl_extend("force", opts, { desc = "New Java interface" }))

-- New enum
vim.keymap.set("n", "<leader>ce", function()
  create_java_class("enum")
end, vim.tbl_extend("force", opts, { desc = "New Java enum" }))

-- New record (Java 14+)
vim.keymap.set("n", "<leader>cr", function()
  create_java_class("record")
end, vim.tbl_extend("force", opts, { desc = "New Java record" }))

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


