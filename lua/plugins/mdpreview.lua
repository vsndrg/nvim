-- Graphical markdown preview inside (patched) Neovide: mdpreview/ in this config.
return {
  dir = vim.fn.stdpath("config") .. "/mdpreview",
  name = "mdpreview",
  ft = "markdown",
  cmd = { "MdPreview", "MdPreviewBuild" },
  config = function()
    require("mdpreview").setup()
  end,
}
