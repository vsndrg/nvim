return {
  name = "Go Build",
  builder = function()
    local go = require("lang.go")
    local root = go.run_root()

    -- Tag-gated files (the course's //go:build model_test tests) are invisible
    -- to `go build` without this, so a broken test file would compile clean.
    local args = { "build" }
    local flag = go.build_tags_flag(root)
    if flag then table.insert(args, flag) end
    table.insert(args, "./...")

    return {
      cmd = { go.go_bin("go") },
      args = args,
      cwd = root,
      components = { { "on_output_quickfix", open = true }, "default" },
    }
  end,
  condition = {
    filetype = { "go" },
  },
}
