vim.bo.expandtab = true
vim.bo.shiftwidth = 4
vim.bo.softtabstop = 4
vim.bo.tabstop = 4

local opts = { buffer = true, silent = true }
local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", opts, { desc = desc }))
end

local function current_file_path()
  return vim.api.nvim_buf_get_name(0)
end

local function has_project_root()
  local file = current_file_path()
  local dir = vim.fs.dirname(file)
  if not dir then
    return false
  end

  local markers = vim.fs.find({ "Cargo.toml", "rust-project.json" }, {
    upward = true,
    path = dir,
    type = "file",
  })
  return #markers > 0
end

local function with_project_fallback(project_fn, standalone_fn)
  if has_project_root() then
    return project_fn()
  end

  return standalone_fn()
end

local function ensure_standalone_terminal()
  local term_buf = tonumber(vim.g.persistent_term_buf) or 0
  if term_buf > 0 and vim.api.nvim_buf_is_valid(term_buf) then
    local wins = vim.fn.win_findbuf(term_buf)
    if #wins > 0 and vim.api.nvim_win_is_valid(wins[1]) then
      vim.api.nvim_set_current_win(wins[1])
      return term_buf
    end
  end

  if type(_G.toggle_persistent_terminal) ~= "function" then
    vim.notify("Persistent terminal toggle is unavailable", vim.log.levels.ERROR)
    return nil
  end

  _G.toggle_persistent_terminal()

  term_buf = tonumber(vim.g.persistent_term_buf) or 0
  if term_buf <= 0 or not vim.api.nvim_buf_is_valid(term_buf) then
    vim.notify("Failed to open persistent terminal", vim.log.levels.ERROR)
    return nil
  end

  local wins = vim.fn.win_findbuf(term_buf)
  if #wins > 0 and vim.api.nvim_win_is_valid(wins[1]) then
    vim.api.nvim_set_current_win(wins[1])
  end

  return term_buf
end

local function run_in_standalone_terminal(command, cwd)
  local buf = ensure_standalone_terminal()
  if not buf then
    return
  end

  local job_id = vim.b[buf].terminal_job_id

  if not job_id or job_id <= 0 then
    _G.toggle_persistent_terminal()
    buf = ensure_standalone_terminal()
    if not buf then
      return
    end
    job_id = vim.b[buf].terminal_job_id
  end

  if not job_id or job_id <= 0 then
    vim.notify("Failed to start terminal shell", vim.log.levels.ERROR)
    return
  end

  local full_command = "cd "
    .. vim.fn.shellescape(cwd)
    .. " && "
    .. command
    .. "\n"
  vim.fn.chansend(job_id, full_command)
  vim.cmd("startinsert")
end

local function run_standalone(kind)
  local file = current_file_path()
  if file == "" or not file:match("%.rs$") then
    vim.notify("Current buffer is not a Rust file", vim.log.levels.WARN)
    return
  end

  if vim.bo.modified then
    vim.cmd.write()
  end

  if vim.fn.executable("rustc") ~= 1 then
    vim.notify("rustc is not executable", vim.log.levels.ERROR)
    return
  end

  local cwd = vim.fs.dirname(file)
  local escaped_file = vim.fn.shellescape(vim.fn.fnamemodify(file, ":t"))
  local output_name = kind == "test" and ".nvim-rs-test-bin" or ".nvim-rs-run-bin"
  local escaped_output = vim.fn.shellescape(output_name)
  local escaped_exec = vim.fn.shellescape("./" .. output_name)
  local compile_and_run

  if kind == "test" then
    compile_and_run = table.concat({
      "rustc --test --edition=2024",
      escaped_file,
      "-o",
      escaped_output,
      "&&",
      escaped_exec,
      "--nocapture;",
      "rm -f",
      escaped_output,
    }, " ")
  else
    compile_and_run = table.concat({
      "rustc --edition=2024",
      escaped_file,
      "-o",
      escaped_output,
      "&&",
      escaped_exec,
      ";",
      "rm -f",
      escaped_output,
    }, " ")
  end

  run_in_standalone_terminal(compile_and_run, cwd)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Hover / Code actions (override global mappings with Rust-enriched versions)
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "K", function() vim.cmd.RustLsp({ "hover", "actions" }) end,
  "Rust hover actions")

map("n", "<leader>ca", function() vim.cmd.RustLsp("codeAction") end,
  "Rust code action (grouped)")

-- ═══════════════════════════════════════════════════════════════════════════
-- Run / Debug / Test
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "<leader>rr", function()
  with_project_fallback(
    function() vim.cmd.RustLsp("runnables") end,
    function() run_standalone("run") end
  )
end, "Runnables")

map("n", "<leader>rd", function()
  with_project_fallback(
    function() vim.cmd.RustLsp("debuggables") end,
    function()
      vim.notify("Debuggables require a Cargo project", vim.log.levels.INFO)
    end
  )
end, "Debuggables")

map("n", "<leader>rt", function()
  with_project_fallback(
    function() vim.cmd.RustLsp("testables") end,
    function() run_standalone("test") end
  )
end, "Testables")

-- ═══════════════════════════════════════════════════════════════════════════
-- Navigation & info
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "<leader>rc", function()
  with_project_fallback(
    function() vim.cmd.RustLsp("openCargo") end,
    function()
      vim.notify("No Cargo.toml found for this standalone file", vim.log.levels.INFO)
    end
  )
end, "Open Cargo.toml")
map("n", "<leader>rp", function() vim.cmd.RustLsp("parentModule") end, "Parent module")
map("n", "<leader>ro", function() vim.cmd.RustLsp("openDocs") end, "Open docs.rs")

-- ═══════════════════════════════════════════════════════════════════════════
-- Diagnostics & macros
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "<leader>re", function() vim.cmd.RustLsp("explainError") end, "Explain error")
map("n", "<leader>rD", function() vim.cmd.RustLsp("renderDiagnostic") end, "Render diagnostic")
map("n", "<leader>rm", function() vim.cmd.RustLsp("expandMacro") end, "Expand macro")

-- ═══════════════════════════════════════════════════════════════════════════
-- Editing helpers
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "J", function() vim.cmd.RustLsp("joinLines") end, "Rust smart join")

map("n", "<leader>rH", function()
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
end, "Toggle inlay hints")

map("n", "<leader>rf", function()
  vim.lsp.buf.format({ async = true })
end, "Format file (rustfmt)")

map("v", "<leader>rf", function()
  vim.lsp.buf.format({ async = true })
end, "Format selection")
