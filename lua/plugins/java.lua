-- nvim-jdtls plugin loading only
-- Actual jdtls configuration is in ftplugin/java.lua
return {
  {
    "mfussenegger/nvim-jdtls",
    ft = "java",
    -- config function removed to avoid duplicate jdtls.start_or_attach()
    -- ftplugin/java.lua handles the actual jdtls setup
  },
}
