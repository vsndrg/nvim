-- golangci-lint diagnostics for Go buffers, run on :w.
--
-- The version of golangci-lint is a property of the project, not of the
-- machine: the ITMO assignments pin it in their Taskfile and install it into
-- `<repo>/bin/<version>/golangci-lint`. Linting with a different binary would
-- report a different rule set than CI, so the repo-local binary wins over
-- anything on $PATH, and the repo's .golangci.yaml is always passed explicitly.
--
--   require("lang.go_lint").run(bufnr)     -- lint the buffer's package
--   require("lang.go_lint").toggle(bufnr)  -- per-buffer on/off
--   require("lang.go_lint").binary(root)   -- resolved golangci-lint, or nil

local M = {}

local ns = vim.api.nvim_create_namespace("golangci_lint")

-- [root] = { job = vim.SystemObj, dirs = { [abs_dir] = true } }
local state = {}
local version_cache = {}
local missing_notified = {}

local CONFIG_NAMES = {
  ".golangci.yaml", ".golangci.yml", ".golangci.toml", ".golangci.json",
}

function M.config_file(root)
  for _, name in ipairs(CONFIG_NAMES) do
    local path = vim.fs.joinpath(root, name)
    if vim.uv.fs_stat(path) then return path end
  end
  return nil
end

-- Repo-local binaries first (`bin/golangci-lint`, `bin/<version>/golangci-lint`),
-- newest by mtime, then whatever is on $PATH.
function M.binary(root)
  local candidates = {}
  vim.list_extend(candidates, vim.fn.glob(vim.fs.joinpath(root, "bin", "golangci-lint"), false, true))
  vim.list_extend(candidates, vim.fn.glob(vim.fs.joinpath(root, "bin", "*", "golangci-lint"), false, true))

  local usable = {}
  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) == 1 then
      local stat = vim.uv.fs_stat(path)
      table.insert(usable, { path = path, mtime = stat and stat.mtime.sec or 0 })
    end
  end
  table.sort(usable, function(a, b) return a.mtime > b.mtime end)
  if usable[1] then return usable[1].path end

  local global = vim.fn.exepath("golangci-lint")
  if global ~= "" then return global end
  return nil
end

-- v1 spells JSON output `--out-format=json`; v2 replaced it with
-- `--output.json.path`. Probed once per binary.
local function major_version(bin)
  if version_cache[bin] then return version_cache[bin] end
  local result = vim.system({ bin, "--version" }, { text = true }):wait(5000)
  local version = ((result.stdout or "") .. (result.stderr or "")):match("version%s+v?(%d+)")
  version_cache[bin] = tonumber(version) or 2
  return version_cache[bin]
end

-- The report is a single JSON line. golangci-lint may append a human-readable
-- stats block after it on the same stream, so fall back to decoding just the
-- first line: that keeps diagnostics working even if --show-stats is renamed.
local function decode_report(stdout)
  if not stdout or stdout == "" then return nil end
  for _, candidate in ipairs({ stdout, stdout:match("^[^\n]*") or "" }) do
    local ok, decoded = pcall(vim.json.decode, candidate)
    if ok and type(decoded) == "table" then return decoded end
  end
  return nil
end

local function severity_of(issue)
  local severity = (issue.Severity or ""):lower()
  if severity == "error" then return vim.diagnostic.severity.ERROR end
  if severity == "info" then return vim.diagnostic.severity.INFO end
  return vim.diagnostic.severity.WARN
end

local function clear_dir(root, dir)
  local entry = state[root]
  if entry then entry.dirs[dir] = true end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fs.dirname(name) == dir then
        vim.diagnostic.reset(ns, bufnr)
      end
    end
  end
end

local function publish(issues, dir, root)
  clear_dir(root, dir)

  local by_buf = {}
  for _, issue in ipairs(issues) do
    local pos = issue.Pos or {}
    local file = pos.Filename
    if file then
      if not vim.startswith(file, "/") then
        file = vim.fs.joinpath(root, file)
      end
      local bufnr = vim.fn.bufnr(file, false)
      if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
        local line = math.max((pos.Line or 1) - 1, 0)
        local last = math.max((issue.LineRange and issue.LineRange.To or pos.Line or 1) - 1, line)
        by_buf[bufnr] = by_buf[bufnr] or {}
        table.insert(by_buf[bufnr], {
          lnum = line,
          end_lnum = last,
          col = math.max((pos.Column or 1) - 1, 0),
          severity = severity_of(issue),
          message = issue.Text or "",
          source = "golangci-lint",
          code = issue.FromLinter,
        })
      end
    end
  end

  for bufnr, diagnostics in pairs(by_buf) do
    vim.diagnostic.set(ns, bufnr, diagnostics)
  end
end

function M.enabled(bufnr)
  if vim.g.go_lint_on_save == false then return false end
  local override = vim.b[bufnr or 0].go_lint_on_save
  if override ~= nil then return override end
  return true
end

function M.toggle(bufnr)
  bufnr = bufnr or 0
  local now = not M.enabled(bufnr)
  vim.b[bufnr].go_lint_on_save = now
  if not now then vim.diagnostic.reset(ns, bufnr) end
  vim.notify("golangci-lint on save: " .. (now and "ON" or "OFF"))
end

function M.run(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not M.enabled(bufnr) then return end

  local go = require("lang.go")
  local root = go.module_root(bufnr)
  -- golangci-lint loads packages through the go command; without a module
  -- there is nothing it can resolve.
  if not root then return end

  local bin = M.binary(root)
  if not bin then
    if not missing_notified[root] then
      missing_notified[root] = true
      vim.notify(
        "golangci-lint not found for this project — run `task lint` once to install the pinned version",
        vim.log.levels.WARN
      )
    end
    return
  end

  local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
  local rel = root == dir and "." or vim.fs.relpath(root, dir)
  local target = rel and (rel == "." and "./..." or "./" .. rel) or "./..."

  local args = { bin, "run", "--path-mode=abs" }
  if major_version(bin) >= 2 then
    -- v2 writes the JSON report and then a human-readable "N issues:" summary
    -- to the same stream, which is not valid JSON as a whole; --show-stats=false
    -- keeps stdout parseable (decode_report also guards against it).
    table.insert(args, "--output.json.path=stdout")
    table.insert(args, "--show-stats=false")
  else
    table.insert(args, "--out-format=json")
  end
  local config = M.config_file(root)
  if config then table.insert(args, "--config=" .. config) end
  table.insert(args, target)

  state[root] = state[root] or { dirs = {} }
  if state[root].job then
    pcall(function() state[root].job:kill(9) end)
  end

  state[root].job = vim.system(args, { cwd = root, text = true }, vim.schedule_wrap(function(result)
    state[root].job = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local decoded = decode_report(result.stdout)
    if not decoded then
      -- Exit code 1 with no JSON means golangci-lint itself failed (bad config,
      -- build error). Build errors are already reported by gopls, so only the
      -- configuration case is worth surfacing.
      if result.code ~= 0 and (result.stderr or ""):match("[Ee]rror") then
        vim.notify("golangci-lint: " .. vim.trim(result.stderr):sub(1, 300), vim.log.levels.WARN)
      end
      return
    end

    publish(decoded.Issues or {}, dir, root)
  end))
end

return M
