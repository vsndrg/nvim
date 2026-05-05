return {
  name = "Clojure Build",
  builder = function()
    local cwd = vim.fn.getcwd()
    local cmd, args

    if vim.fn.filereadable(cwd .. "/project.clj") == 1 then
      cmd, args = "lein", { "uberjar" }
    elseif vim.fn.filereadable(cwd .. "/deps.edn") == 1 then
      cmd, args = "clj", { "-T:build", "uber" }
    elseif vim.fn.filereadable(cwd .. "/build.boot") == 1 then
      cmd, args = "boot", { "build" }
    else
      cmd, args = "lein", { "uberjar" }
    end

    return {
      cmd = { cmd },
      args = args,
      cwd = cwd,
      components = { { "on_output_quickfix", open = true }, "default" },
    }
  end,
  condition = {
    filetype = { "clojure", "clojurescript" },
  },
}
