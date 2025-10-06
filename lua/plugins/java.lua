return {
  {
    "mfussenegger/nvim-jdtls",
    ft = "java",
    dependencies = {
      "neovim/nvim-lspconfig",
      "williamboman/mason.nvim", -- optional but helpful if you use Mason to install jdtls
    },
    config = function()
      local jdtls = require("jdtls")

      -- project root (same logic as your original)
      local root_dir = require("jdtls.setup").find_root({ ".git", "mvnw", "gradlew" })

      -- helper values
      local sep = package.config:sub(1,1)
      local data_dir = vim.fn.stdpath("data")
      local project_name = vim.fn.fnamemodify(vim.fn.getcwd(), ":p:h:t")
      local workspace_dir = data_dir .. sep .. "jdtls-workspace" .. sep .. project_name
      local os_name = vim.loop.os_uname().sysname

      -- try to locate the equinox launcher jar inside mason's jdtls package
      local mason_jdtls = table.concat({ data_dir, "mason", "packages", "jdtls" }, sep)
      local glob_pattern = mason_jdtls .. sep .. "plugins" .. sep .. "org.eclipse.equinox.launcher_*.jar"
      local equinox_jar = vim.fn.glob(glob_pattern)

      -- platform config folder name used by eclipse.jdt.ls (win/linux/mac)
      local config_name = (os_name == "Windows_NT" and "win")
                        or (os_name == "Linux" and "linux")
                        or "mac"
      local config_path = mason_jdtls .. sep .. "config_" .. config_name

      -- build cmd; if we didn't find the equinox jar, fall back to the "jdtls" wrapper
      local cmd
      if equinox_jar ~= "" then
        cmd = {
          "java",
          "-Declipse.application=org.eclipse.jdt.ls.core.id1",
          "-Dosgi.bundles.defaultStartLevel=4",
          "-Declipse.product=org.eclipse.jdt.ls.core.product",
          "-Dlog.protocol=true",
          "-Dlog.level=ALL",
          "-Xmx1g",
          "--add-modules=ALL-SYSTEM",
          "--add-opens", "java.base/java.util=ALL-UNNAMED",
          "--add-opens", "java.base/java.lang=ALL-UNNAMED",
          "-jar", equinox_jar,
          "-configuration", config_path,
          "-data", workspace_dir,
        }
      else
        -- fallback: try wrapper `jdtls` (user-provided) — mirrors your original comment.
        cmd = { "jdtls" }
      end

      -- final jdtls config
      local config = {
        cmd = cmd,
        root_dir = root_dir,
        settings = {
          java = {},
        },
        init_options = {
          bundles = {}, -- add debug/test bundles here if you want java-debug/java-test
        },
      }

      -- start or attach jdtls
      jdtls.start_or_attach(config)
    end,
  },
}
