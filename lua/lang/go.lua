-- Go language orchestration: gopls server config, build-tag discovery, buffer
-- keymaps, format + organize-imports on save, run/test/lint in a bottom split,
-- go.mod bootstrap for scratch files, and neotest/dap wiring helpers.
--
-- Public entrypoints:
--   require("lang.go").setup()                  -- one-shot startup setup
--   require("lang.go").setup_dap()              -- (re)registers nvim-dap-go
--   require("lang.go").neotest_adapters()       -- returns adapter list
--   require("lang.go").build_tags(root)         -- project //go:build tags
--   require("lang.go").build_tags_flag(root)    -- "-tags=a,b" or nil
--   require("lang.go").module_root(bufnr)       -- dir holding go.work / go.mod

local M = {}

M.filetypes = { "go", "gomod", "gosum", "gowork", "gotmpl" }

-- ─────────────────────────────────────────────────────────────────────────────
-- Toolchain discovery
-- ─────────────────────────────────────────────────────────────────────────────
-- A GUI Neovim started outside a login shell inherits a bare PATH, so `go`,
-- `gopls` and `dlv` are invisible even though they are installed. Patch the
-- editor's own PATH instead of requiring the launcher to be fixed.

local function gopath_bin()
  if vim.env.GOBIN and vim.env.GOBIN ~= "" then return vim.env.GOBIN end
  local gopath = vim.env.GOPATH
  if gopath and gopath ~= "" then
    return vim.fs.joinpath(vim.split(gopath, ":", { plain = true })[1], "bin")
  end
  return vim.fs.joinpath(vim.env.HOME or "", "go", "bin")
end

local function ensure_path()
  local candidates = { "/usr/local/go/bin", "/opt/homebrew/bin", gopath_bin() }
  for _, dir in ipairs(candidates) do
    if dir ~= "" and vim.uv.fs_stat(dir) and not (":" .. vim.env.PATH .. ":"):find(":" .. dir .. ":", 1, true) then
      vim.env.PATH = dir .. ":" .. vim.env.PATH
    end
  end
end

function M.go_bin(name)
  local path = vim.fn.exepath(name)
  if path ~= "" then return path end
  local guess = vim.fs.joinpath(gopath_bin(), name)
  if vim.fn.executable(guess) == 1 then return guess end
  return name
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Project roots
-- ─────────────────────────────────────────────────────────────────────────────

local function find_upward(names, from)
  local found = vim.fs.find(names, { upward = true, path = from, type = "file" })
  return found and found[1] or nil
end

local function buf_dir(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr or 0)
  if fname == "" then return vim.uv.cwd() end
  return vim.fs.dirname(fname)
end

-- go.work wins over go.mod: in workspace mode gopls must be rooted at the
-- workspace, otherwise cross-module navigation resolves to the module cache.
function M.module_root(bufnr)
  local dir = buf_dir(bufnr)
  local work = find_upward({ "go.work" }, dir)
  if work then return vim.fs.dirname(work) end
  local mod = find_upward({ "go.mod" }, dir)
  if mod then return vim.fs.dirname(mod) end
  return nil
end

-- Root used for running commands: the module root when there is one, the
-- file's own directory otherwise (scratch files live in their own package).
local function run_root(bufnr)
  return M.module_root(bufnr) or buf_dir(bufnr)
end

M.run_root = run_root

-- ─────────────────────────────────────────────────────────────────────────────
-- Build-tag discovery
-- ─────────────────────────────────────────────────────────────────────────────
-- Files gated behind `//go:build <tag>` are invisible to gopls unless the tag
-- is passed in buildFlags — the file shows up greyed out with no completion and
-- no diagnostics. The ITMO course ships its tests exactly that way
-- (`//go:build model_test`, `//go:build performance_test`), so the tags are
-- discovered per project rather than hardcoded: every tag mentioned by a
-- `//go:build` line or by a `-tags=` flag in the project's task runner is fed
-- to gopls, neotest and delve.

-- Constraints the toolchain defines itself; passing these to `-tags` is either
-- meaningless or actively wrong.
local RESERVED_TAGS = {}
for _, name in ipairs({
  -- GOOS
  "aix", "android", "darwin", "dragonfly", "freebsd", "hurd", "illumos", "ios",
  "js", "linux", "nacl", "netbsd", "openbsd", "plan9", "solaris", "wasip1", "windows", "zos",
  -- GOARCH
  "386", "amd64", "amd64p32", "arm", "arm64", "arm64be", "armbe", "loong64",
  "mips", "mips64", "mips64le", "mips64p32", "mips64p32le", "mipsle", "ppc",
  "ppc64", "ppc64le", "riscv", "riscv64", "s390", "s390x", "sparc", "sparc64", "wasm",
  -- Toolchain / meta
  "cgo", "gc", "gccgo", "race", "msan", "asan", "unix", "boringcrypto",
  "purego", "ignore", "generate", "math_big_pure_go", "osusergo", "netgo",
}) do
  RESERVED_TAGS[name] = true
end

local function is_project_tag(word)
  if RESERVED_TAGS[word] then return false end
  if word:match("^go1%.?%d*$") then return false end
  return word:match("^[%a_][%w_]*$") ~= nil
end

local SKIP_DIRS = {
  [".git"] = true, [".github"] = true, [".idea"] = true, [".vscode"] = true,
  bin = true, vendor = true, node_modules = true, testdata = true, target = true,
}

-- `//go:build` must appear before the package clause, so only the file header
-- is read — no full-file scan on projects with large sources.
local function collect_file_tags(path, acc)
  local fd = io.open(path, "r")
  if not fd then return end
  for _ = 1, 40 do
    local line = fd:read("l")
    if not line then break end
    local expr = line:match("^//go:build%s+(.+)$")
    if expr then
      for word in expr:gmatch("[%w_%.]+") do
        if is_project_tag(word) then acc[word] = true end
      end
      break
    end
    if line:match("^package%s") then break end
  end
  fd:close()
end

-- Task runners spell the tags out in the command line that CI uses; that is the
-- authoritative set even for tags no local file carries yet.
local function collect_runner_tags(root, acc)
  for _, name in ipairs({ "Taskfile.yml", "Taskfile.yaml", "Makefile", "justfile", "Justfile" }) do
    local path = vim.fs.joinpath(root, name)
    local fd = io.open(path, "r")
    if fd then
      local content = fd:read("a") or ""
      fd:close()
      for list in content:gmatch("%-%-?tags[=%s]+[\"']?([%w_,]+)") do
        for word in list:gmatch("[%w_]+") do
          if is_project_tag(word) then acc[word] = true end
        end
      end
    end
  end
end

local tag_cache = {}

-- Sorted list of project-defined build tags, cached per root.
function M.build_tags(root)
  root = root or run_root()
  if not root then return {} end
  if tag_cache[root] then return tag_cache[root] end

  local acc = {}
  collect_runner_tags(root, acc)

  local ok = pcall(function()
    for name, type_ in vim.fs.dir(root, {
      depth = 8,
      skip = function(dirname) return not SKIP_DIRS[dirname] end,
    }) do
      if type_ == "file" and name:sub(-3) == ".go" then
        collect_file_tags(vim.fs.joinpath(root, name), acc)
      end
    end
  end)
  if not ok then acc = acc or {} end

  local tags = vim.tbl_keys(acc)
  table.sort(tags)
  tag_cache[root] = tags
  return tags
end

function M.build_tags_flag(root)
  local tags = M.build_tags(root)
  if #tags == 0 then return nil end
  return "-tags=" .. table.concat(tags, ",")
end

-- Drops the cache and restarts gopls so the new tag set reaches the server.
function M.refresh_build_tags(root)
  root = root or run_root()
  tag_cache[root] = nil
  local tags = M.build_tags(root)
  pcall(vim.cmd, "LspRestart gopls")
  M.setup_dap()
  vim.notify(
    #tags > 0 and ("Go build tags: " .. table.concat(tags, ", ")) or "Go build tags: none",
    vim.log.levels.INFO
  )
end

-- ─────────────────────────────────────────────────────────────────────────────
-- gopls
-- ─────────────────────────────────────────────────────────────────────────────

local function gopls_capabilities()
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  local ok_blink, blink = pcall(require, "blink.cmp")
  if ok_blink and blink.get_lsp_capabilities then
    capabilities = blink.get_lsp_capabilities(capabilities)
  end
  -- Matches the rest of this config: completions are inserted plain, without
  -- placeholder jumps (see lua/plugins/lsp.lua).
  capabilities.textDocument.completion.completionItem.snippetSupport = false
  return capabilities
end

-- Analyzers beyond the vet defaults. The course lints with golangci-lint
-- (govet+shadow, staticcheck, unparam, …); mirroring the overlapping subset
-- here means the editor flags them while typing instead of after :w.
local GOPLS_ANALYSES = {
  nilness = true,
  shadow = true,
  unusedparams = true,
  unusedwrite = true,
  unusedvariable = true,
  useany = true,
  unusedresult = true,
  appends = true,
  defers = true,
  slog = true,
  sortslice = true,
  stringintconv = true,
  embed = true,
  -- fieldalignment stays off: it fires on nearly every struct and says nothing
  -- about correctness.
  fieldalignment = false,
}

function M.setup_server()
  vim.lsp.config("gopls", {
    cmd = { M.go_bin("gopls") },
    capabilities = gopls_capabilities(),
    -- `.git` is deliberately absent: a scratch .go file inside an unrelated git
    -- repo would otherwise root gopls at the repo and report the whole tree as
    -- broken. Without a marker we fall back to the file's own directory.
    root_dir = function(bufnr, on_dir)
      on_dir(M.module_root(bufnr) or buf_dir(bufnr))
    end,
    -- Build tags are a per-project fact, so they are stamped onto the client's
    -- own settings copy rather than the shared config table (gopls pulls them
    -- back through workspace/configuration right after `initialized`).
    on_init = function(client)
      local flag = M.build_tags_flag(client.root_dir)
      client.settings = vim.tbl_deep_extend("force", vim.deepcopy(client.settings or {}), {
        gopls = { buildFlags = flag and { flag } or {} },
      })
    end,
    settings = {
      gopls = {
        -- gofumpt's stricter rules are applied by gopls itself, so
        -- `vim.lsp.buf.format` and the save hook need no external binary.
        gofumpt = true,
        staticcheck = true,
        analyses = GOPLS_ANALYSES,
        -- Ask gopls to surface every diagnostic it computes, including the
        -- ones it would normally hide behind a code action.
        diagnosticsDelay = "250ms",
        diagnosticsTrigger = "Edit",
        analysisProgressReporting = true,
        completeUnimported = true,
        completeFunctionCalls = false,
        usePlaceholders = false,
        matcher = "Fuzzy",
        symbolMatcher = "FastFuzzy",
        semanticTokens = true,
        directoryFilters = { "-bin", "-vendor", "-node_modules", "-.git" },
        codelenses = {
          generate = true,
          gc_details = true,
          test = true,
          tidy = true,
          upgrade_dependency = true,
          regenerate_cgo = false,
          vendor = false,
        },
        -- Type-level hints only. Parameter-name hints are the noisy ones and
        -- stay off; toggle everything per buffer with <leader>gh.
        hints = {
          assignVariableTypes = true,
          compositeLiteralFields = true,
          compositeLiteralTypes = false,
          constantValues = true,
          functionTypeParameters = true,
          rangeVariableTypes = true,
          parameterNames = false,
        },
      },
    },
  })
  vim.lsp.enable("gopls")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Formatting: gofumpt (via gopls) + organize imports
-- ─────────────────────────────────────────────────────────────────────────────
-- Per-buffer override: vim.b[buf].go_format_on_save (nil → on).

function M.should_format_on_save(bufnr)
  local override = vim.b[bufnr or 0].go_format_on_save
  if override ~= nil then return override end
  return true
end

function M.toggle_format_on_save(bufnr)
  bufnr = bufnr or 0
  vim.b[bufnr].go_format_on_save = not M.should_format_on_save(bufnr)
  vim.notify("Go format on save: " .. (vim.b[bufnr].go_format_on_save and "ON" or "OFF"))
end

function M.organize_imports(bufnr, timeout_ms)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })
  local client = clients[1]
  if not client then return end

  local params = vim.lsp.util.make_range_params(0, client.offset_encoding)
  params.context = { only = { "source.organizeImports" }, diagnostics = {} }

  local responses = client:request_sync("textDocument/codeAction", params, timeout_ms or 1500, bufnr)
  for _, action in ipairs(responses and responses.result or {}) do
    -- gopls answers resolved actions, so `edit` is present; a command-only
    -- action would need a workspace/executeCommand round trip.
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
    end
  end
end

function M.format(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  M.organize_imports(bufnr)
  vim.lsp.buf.format({ bufnr = bufnr, async = false, timeout_ms = 3000, name = "gopls" })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Command runner — bottom terminal split, one at a time
-- ─────────────────────────────────────────────────────────────────────────────

local runner_buf = nil

local function close_runner()
  if runner_buf and vim.api.nvim_buf_is_valid(runner_buf) then
    for _, win in ipairs(vim.fn.win_findbuf(runner_buf)) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    pcall(vim.api.nvim_buf_delete, runner_buf, { force = true })
  end
  runner_buf = nil
end

-- `cmd` is an argv list; `cwd` the directory to run it in.
function M.run_in_split(cmd, cwd)
  if vim.bo.modified and vim.bo.buftype == "" then
    vim.cmd.write()
  end
  close_runner()

  local origin = vim.api.nvim_get_current_win()
  vim.cmd("belowright new")
  vim.cmd("resize " .. math.floor(vim.o.lines * 0.3))
  runner_buf = vim.api.nvim_get_current_buf()

  -- lua/autocmds.lua wipes terminal buffers as soon as the job exits; test and
  -- build output must outlive the process, so opt this buffer out.
  vim.b[runner_buf].keep_term_output = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"

  vim.fn.jobstart(cmd, { cwd = cwd, term = true })

  local function close()
    close_runner()
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = runner_buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = runner_buf, nowait = true, silent = true })
end

-- True when the project ships a Taskfile that defines `task` and the runner is
-- installed. The course's Taskfile is the source of truth for how tests and the
-- pinned golangci-lint are meant to be invoked.
local function has_task_runner(root, task)
  if vim.fn.executable("task") ~= 1 then return false end
  for _, name in ipairs({ "Taskfile.yml", "Taskfile.yaml" }) do
    local fd = io.open(vim.fs.joinpath(root, name), "r")
    if fd then
      local content = fd:read("a") or ""
      fd:close()
      if content:match("\n%s*" .. task .. ":%s") or content:match("\n%s*" .. task .. ":\n") then
        return true
      end
    end
  end
  return false
end

M.has_task_runner = has_task_runner

-- Package path relative to the module root, in the `./internal/digest` form
-- `go test` expects.
local function package_pattern(bufnr)
  local root = M.module_root(bufnr)
  local dir = buf_dir(bufnr)
  if not root then return "." end
  if root == dir then return "." end
  local rel = vim.fs.relpath(root, dir)
  return rel and ("./" .. rel) or "./..."
end

local function go_cmd(args)
  local cmd = { M.go_bin("go") }
  vim.list_extend(cmd, args)
  return cmd
end

local function with_tags(args, root)
  local flag = M.build_tags_flag(root)
  if flag then table.insert(args, flag) end
  return args
end

function M.run()
  local bufnr = vim.api.nvim_get_current_buf()
  local root = run_root(bufnr)
  if M.module_root(bufnr) then
    M.run_in_split(go_cmd(with_tags({ "run", package_pattern(bufnr) }, root)), root)
  else
    -- No module: `go run <file>` still works for a self-contained main.
    local file = vim.api.nvim_buf_get_name(bufnr)
    M.run_in_split(go_cmd({ "run", vim.fn.fnamemodify(file, ":t") }), buf_dir(bufnr))
  end
end

function M.test_package()
  local bufnr = vim.api.nvim_get_current_buf()
  local root = run_root(bufnr)
  local args = with_tags({ "test", "-v", "-race", "-count=1" }, root)
  table.insert(args, package_pattern(bufnr))
  M.run_in_split(go_cmd(args), root)
end

function M.test_all()
  local root = run_root()
  if has_task_runner(root, "test") then
    M.run_in_split({ "task", "test" }, root)
    return
  end
  local args = with_tags({ "test", "-v", "-race", "-count=1" }, root)
  table.insert(args, "./...")
  M.run_in_split(go_cmd(args), root)
end

function M.build()
  local root = run_root()
  M.run_in_split(go_cmd(with_tags({ "build", "./..." }, root)), root)
end

function M.vet()
  local root = run_root()
  M.run_in_split(go_cmd(with_tags({ "vet", "./..." }, root)), root)
end

function M.mod_tidy()
  local root = run_root()
  M.run_in_split(go_cmd({ "mod", "tidy" }), root)
end

-- Full-project lint in the split. Prefers `task lint`, which also installs the
-- exact golangci-lint version the assignment pins.
function M.lint_project()
  local root = run_root()
  if has_task_runner(root, "lint") then
    M.run_in_split({ "task", "lint" }, root)
    return
  end
  local lint = require("lang.go_lint")
  local bin = lint.binary(root)
  if not bin then
    vim.notify("golangci-lint not found (run `task lint` once to install it)", vim.log.levels.WARN)
    return
  end
  local args = { bin, "run" }
  local config = lint.config_file(root)
  if config then table.insert(args, "--config=" .. config) end
  table.insert(args, "./...")
  M.run_in_split(args, root)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- go.mod bootstrap for scratch files
-- ─────────────────────────────────────────────────────────────────────────────
-- gopls is nearly blind on a .go file that belongs to no module: no imports
-- resolve, no diagnostics, no completion beyond the current file. Offer to
-- create the module instead of leaving the buffer half-working.

local bootstrap_asked = {}

local function module_name_for(dir)
  local base = vim.fs.basename(dir):lower():gsub("[^%w_%-%.]", "-"):gsub("^%-+", "")
  if base == "" then base = "scratch" end
  return base
end

function M.init_module(dir, silent)
  dir = dir or buf_dir()
  local name = module_name_for(dir)
  local result = vim.system({ M.go_bin("go"), "mod", "init", name }, { cwd = dir, text = true }):wait()
  if result.code ~= 0 then
    vim.notify("go mod init failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
    return false
  end
  if not silent then
    vim.notify("Created " .. vim.fs.joinpath(dir, "go.mod") .. " (module " .. name .. ")")
  end
  pcall(vim.cmd, "LspRestart gopls")
  return true
end

local function maybe_bootstrap_module(bufnr)
  if vim.g.go_no_auto_module then return end
  if vim.bo[bufnr].buftype ~= "" then return end
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if fname == "" then return end
  if M.module_root(bufnr) then return end

  local dir = vim.fs.dirname(fname)
  if bootstrap_asked[dir] then return end
  bootstrap_asked[dir] = true

  vim.schedule(function()
    local choice = vim.fn.confirm(
      ("No go.mod for %s.\ngopls needs a module for imports and diagnostics.\nCreate one in %s?")
        :format(vim.fs.basename(fname), dir),
      "&Yes\n&No", 1
    )
    if choice == 1 then M.init_module(dir) end
  end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Inlay hints
-- ─────────────────────────────────────────────────────────────────────────────

local function toggle_inlay_hints(bufnr)
  local enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })
  vim.lsp.inlay_hint.enable(not enabled, { bufnr = bufnr })
  vim.notify("Go inlay hints: " .. (not enabled and "ON" or "OFF"))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Buffer-local keymaps
-- ─────────────────────────────────────────────────────────────────────────────

-- Wraps a go.nvim command so a not-yet-loaded plugin reports itself instead of
-- throwing E492.
local function go_command(command)
  return function()
    if vim.fn.exists(":" .. command:match("^%S+")) == 0 then
      vim.notify("go.nvim command not available: " .. command, vim.log.levels.WARN)
      return
    end
    vim.cmd(command)
  end
end

local function neotest_action(fn)
  return function(bufnr)
    local ok, neotest = pcall(require, "neotest")
    if not ok then
      vim.notify("neotest is not available", vim.log.levels.WARN)
      return
    end
    fn(neotest, bufnr)
  end
end

-- One source of truth for the buffer-local keymaps and for the :GoKeys
-- cheatsheet — a binding can never be listed but unmapped, or the reverse.
-- Each action receives the buffer it was invoked from.
M.keymaps = {
  {
    group = "Run & build",
    items = {
      { "<leader>gr", "run current package",            M.run },
      { "<leader>gb", "build ./...",                    M.build },
      { "<leader>gv", "go vet ./...",                   M.vet },
      { "<leader>gt", "test this package (split)",      M.test_package },
      { "<leader>gT", "test everything (task test)",    M.test_all },
    },
  },
  {
    group = "Tests (neotest)",
    items = {
      { "<leader>tt", "run nearest test",  neotest_action(function(n) n.run.run() end) },
      { "<leader>tf", "run file",          neotest_action(function(n) n.run.run(vim.fn.expand("%")) end) },
      { "<leader>tT", "run whole project", neotest_action(function(n, b) n.run.run(run_root(b)) end) },
      { "<leader>td", "debug nearest test", neotest_action(function(n) n.run.run({ strategy = "dap" }) end) },
      { "<leader>ts", "toggle summary",    neotest_action(function(n) n.summary.toggle() end) },
      { "<leader>to", "open output",       neotest_action(function(n) n.output.open({ enter = true }) end) },
      { "<leader>tx", "stop run",          neotest_action(function(n) n.run.stop() end) },
      { "<leader>gD", "debug test under cursor (delve)", function()
        local ok, dap_go = pcall(require, "dap-go")
        if not ok then
          vim.notify("nvim-dap-go is not available", vim.log.levels.WARN)
          return
        end
        dap_go.debug_test()
      end },
    },
  },
  {
    group = "Lint & format",
    items = {
      { "<leader>gl", "golangci-lint, whole project",  M.lint_project },
      { "<leader>gL", "toggle lint-on-save",           function(b) require("lang.go_lint").toggle(b) end },
      { "<leader>gf", "format buffer (gofumpt)",       function(b) M.format(b) end },
      { "<leader>gi", "organize imports",              function(b) M.organize_imports(b) end },
      { "<leader>gF", "toggle format-on-save",         function(b) M.toggle_format_on_save(b) end },
      { "<leader>gh", "toggle inlay hints",            function(b) toggle_inlay_hints(b) end },
    },
  },
  {
    group = "Code generation",
    items = {
      { "<leader>ge", "insert if err != nil",          go_command("GoIfErr") },
      { "<leader>gs", "fill struct",                   go_command("GoFillStruct") },
      { "<leader>gS", "fill switch",                   go_command("GoFillSwitch") },
      { "<leader>ga", "add struct tags",               go_command("GoAddTag") },
      { "<leader>gA", "remove struct tags",            go_command("GoRmTag") },
      { "<leader>gI", "implement interface",           go_command("GoImpl") },
      { "<leader>gu", "generate test for function",    go_command("GoAddTest") },
      { "<leader>gU", "generate tests for exported",   go_command("GoAddExpTest") },
    },
  },
  {
    group = "Navigate & project",
    items = {
      { "<leader>go", "jump between file and _test.go", go_command("GoAlt!") },
      { "<leader>gd", "godoc for symbol",               go_command("GoDoc") },
      { "<leader>gc", "toggle coverage overlay",        go_command("GoCoverage") },
      { "<leader>gC", "clear coverage overlay",         go_command("GoCoverage -r") },
      { "<leader>gm", "go mod tidy",                    M.mod_tidy },
      { "<leader>gn", "go mod init here",               function() M.init_module() end },
      { "<leader>gp", "re-scan build tags, restart gopls", function() M.refresh_build_tags() end },
      { "<leader>g?", "this cheatsheet (:GoKeys)",      function() M.show_keymaps() end },
    },
  },
}

local function on_gopls_attach(_, bufnr)
  for _, section in ipairs(M.keymaps) do
    for _, item in ipairs(section.items) do
      local lhs, desc, action = item[1], item[2], item[3]
      vim.keymap.set("n", lhs, function() action(bufnr) end, {
        buffer = bufnr,
        silent = true,
        desc = "Go: " .. desc,
      })
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- :GoKeys — cheatsheet rendered from M.keymaps
-- ─────────────────────────────────────────────────────────────────────────────

function M.show_keymaps()
  local lines, highlights = {}, {}
  local leader = vim.g.mapleader == " " and "<Space>" or (vim.g.mapleader or "\\")

  local function add(text, hl)
    table.insert(lines, text)
    if hl then table.insert(highlights, { line = #lines - 1, hl = hl }) end
  end

  add("  Go keymaps — buffer-local, active while gopls is attached", "Comment")
  add("")

  for _, section in ipairs(M.keymaps) do
    add("  " .. section.group, "Title")
    for _, item in ipairs(section.items) do
      local lhs = item[1]:gsub("<leader>", leader)
      add(string.format("    %-14s %s", lhs, item[2]))
    end
    add("")
  end

  add("  Also: K hover · gd definition · gr references · rn rename · " .. leader .. "ca code action", "Comment")
  add("  Commands: :GoKeys · :GoProjectTags · go.nvim's :Go* · :Lazy · :LspInfo", "Comment")
  add("")
  add("  q / <Esc> to close", "Comment")

  local width = 0
  for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line)) end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  local ns = vim.api.nvim_create_namespace("go_keys")
  for _, item in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns, item.line, 0, { end_col = #lines[item.line + 1], hl_group = item.hl })
  end
  -- Highlight the key column of every mapping line.
  for i, line in ipairs(lines) do
    local s, e = line:find("^    %S+")
    if s then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 4, { end_col = e, hl_group = "Identifier" })
    end
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Go ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
  vim.keymap.set("n", "<C-c>", close, opts)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Autocommands
-- ─────────────────────────────────────────────────────────────────────────────

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("GoLang", { clear = true })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= "gopls" then return end
      on_gopls_attach(client, args.buf)
      if vim.lsp.inlay_hint then
        vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = "*.go",
    callback = function(args) maybe_bootstrap_module(args.buf) end,
  })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    pattern = { "*.go", "go.mod" },
    callback = function(args)
      if not M.should_format_on_save(args.buf) then return end
      M.format(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.go",
    callback = function(args) require("lang.go_lint").run(args.buf) end,
  })

  -- Taskfile edits change the tag set CI uses; re-read it instead of making the
  -- user remember <leader>gp.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "Taskfile.yml", "Taskfile.yaml", "Makefile" },
    callback = function(args)
      local root = M.module_root(args.buf)
      if root then tag_cache[root] = nil end
    end,
  })

  -- nvim-dap is owned by lua/plugins/debug.lua; register the Go adapter the
  -- first time a Go file shows up so delve gets this project's build tags.
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "go",
    callback = function() M.setup_dap() end,
  })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- DAP (delve via nvim-dap-go)
-- ─────────────────────────────────────────────────────────────────────────────

local dap_tags_applied = nil

-- Re-runs nvim-dap-go's setup whenever the active project's build tags differ
-- from the ones delve was configured with — tests behind `//go:build
-- model_test` are otherwise "no test files" under the debugger.
function M.setup_dap(force)
  local ok, dap_go = pcall(require, "dap-go")
  if not ok then return end

  local flag = M.build_tags_flag(run_root()) or ""
  if not force and dap_tags_applied == flag then return end
  dap_tags_applied = flag

  local ok_dap, dap = pcall(require, "dap")
  if not ok_dap then return end

  -- nvim-dap-go appends to dap.configurations.go instead of replacing it, so
  -- re-running setup on a project switch would stack duplicates.
  dap.configurations.go = {}

  dap_go.setup({
    delve = {
      path = M.go_bin("dlv"),
      build_flags = flag,
      detached = true,
    },
  })

  table.insert(dap.configurations.go, {
    type = "go",
    name = "Attach to process (delve)",
    mode = "local",
    request = "attach",
    processId = function() return require("dap.utils").pick_process() end,
  })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Neotest
-- ─────────────────────────────────────────────────────────────────────────────

function M.neotest_adapters()
  local ok, golang = pcall(require, "neotest-golang")
  if not ok then return {} end

  -- Every option is a function so the tags are resolved per run: switching
  -- between assignments must not require restarting Neovim.
  local function with_current_tags(base)
    local args = vim.deepcopy(base)
    local flag = M.build_tags_flag(run_root())
    if flag then table.insert(args, flag) end
    return args
  end

  return {
    golang({
      -- Mirrors `task test`: `go test -tags=… -race -count=1 -v`.
      go_test_args = function() return with_current_tags({ "-v", "-race", "-count=1" }) end,
      -- Discovery runs `go list`, which reports TestGoFiles per package. Without
      -- the tags a `//go:build model_test` file is not listed as a test file at
      -- all and neotest finds nothing to run.
      go_list_args = function() return with_current_tags({}) end,
      -- neotest-golang re-runs nvim-dap-go's setup before debugging, which would
      -- otherwise drop the build flags configured in M.setup_dap.
      dap_go_opts = function()
        return {
          delve = {
            path = M.go_bin("dlv"),
            build_flags = M.build_tags_flag(run_root()) or "",
            detached = true,
          },
        }
      end,
      dap_mode = "dap-go",
      testify_enabled = true,
    }),
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public setup
-- ─────────────────────────────────────────────────────────────────────────────

function M.setup()
  ensure_path()
  M.setup_server()
  M.setup_autocmds()

  vim.api.nvim_create_user_command("GoProjectTags", function()
    M.refresh_build_tags()
  end, { desc = "Re-scan //go:build tags and restart gopls" })

  vim.api.nvim_create_user_command("GoKeys", function()
    M.show_keymaps()
  end, { desc = "Show the Go keymap cheatsheet" })
end

return M
