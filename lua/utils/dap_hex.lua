-- Hex (and octal/binary) display of debugger values for nvim-dap / nvim-dap-ui.
--
-- The DAP way of asking for this -- `format = { hex = true }` on the `variables`
-- request -- is a dead end with codelldb: it never advertises
-- `supportsValueFormattingOptions` and silently ignores the field. Two
-- codelldb-specific mechanisms are used instead:
--
--   * `_adapterSettings { displayFormat = ... }`, a session-wide switch that
--     re-formats every value, including already expanded children;
--   * a `,x` suffix on an expression: `evaluate` returns the value formatted as
--     hex *and* a variable reference whose children inherit that format, so one
--     request re-formats a whole subtree.
--
-- The per-object mode marks expressions (a variable's `evaluateName`) and
-- rewrites the `variables` responses carrying them: the value string is taken
-- from the `,x` evaluation and the variable reference is swapped for the one it
-- returned, which puts the marked variable and all of its children in hex while
-- everything else stays decimal.
--
-- Known limitation: values produced by a synthetic provider (Rust `Vec`,
-- `HashMap`, ...) ignore the format, both per-object and session-wide. Their
-- `[raw]` child does honour it.

local M = {}

-- Marked expressions (`evaluateName` -> true). Kept across sessions.
local marks = {}

-- What the UI has fetched so far, used to resolve the variable under the
-- cursor: variablesReference -> { [name] = variable }.
local children = {}
-- Scope name -> variablesReference, for the current frame.
local scope_refs = {}
-- Watch expression -> variablesReference of its last evaluation.
local watch_refs = {}

local global_format = "auto"

-- Set by install(), the unwrapped `Session.request`. Used for the extra
-- requests this module makes, so they don't re-enter the wrapper.
local orig_request

local FORMATS = { "auto", "hex", "decimal", "binary" }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "DAP hex" })
end

local function session()
  return require("dap").session()
end

-- Only lldb-based adapters understand `_adapterSettings` and the `,x` suffix.
local function supported(s)
  local kind = s and s.config and s.config.type
  return kind == "codelldb" or kind == "lldb"
end

local function invalidate()
  children = {}
  scope_refs = {}
  watch_refs = {}
end

-- dap-ui re-renders scopes, watches, threads and frames whenever it sees a
-- `scopes` response it did not request itself, so asking for the scopes of the
-- current frame is enough to redraw everything with the new formatting.
local function refresh()
  local s = session()
  local frame = s and s.current_frame
  if not frame then
    return
  end
  orig_request(s, "scopes", { frameId = frame.id }, function() end)
end

--- Session-wide value format.

local function apply_global_format(s, fmt, on_done)
  orig_request(s, "_adapterSettings", { displayFormat = fmt }, function(err)
    if err then
      notify("adapter rejected displayFormat: " .. tostring(err.message or err), vim.log.levels.ERROR)
      return
    end
    if on_done then
      on_done()
    end
  end)
end

---@param fmt "auto"|"hex"|"decimal"|"binary"
function M.set_global_format(fmt)
  if not vim.tbl_contains(FORMATS, fmt) then
    notify("unknown format: " .. tostring(fmt), vim.log.levels.ERROR)
    return
  end
  local s = session()
  if not s then
    notify("no active debug session", vim.log.levels.WARN)
    return
  end
  if not supported(s) then
    notify("adapter '" .. tostring(s.config.type) .. "' has no value formats", vim.log.levels.WARN)
    return
  end
  apply_global_format(s, fmt, function()
    global_format = fmt
    notify("value format: " .. fmt)
    refresh()
  end)
end

function M.toggle_global()
  M.set_global_format(global_format == "hex" and "auto" or "hex")
end

function M.clear_marks()
  local count = vim.tbl_count(marks)
  marks = {}
  notify(count == 0 and "no per-object hex marks" or ("cleared %d per-object hex mark(s)"):format(count))
  refresh()
end

function M.pick_format()
  local choices = {
    { label = "auto (adapter default)", format = "auto" },
    { label = "hex", format = "hex" },
    { label = "decimal", format = "decimal" },
    { label = "binary", format = "binary" },
    { label = "clear per-object hex marks", clear = true },
  }
  vim.ui.select(choices, {
    prompt = "Debug value format",
    format_item = function(item)
      if item.format == global_format then
        return item.label .. "  (current)"
      end
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.clear then
      M.clear_marks()
    else
      M.set_global_format(choice.format)
    end
  end)
end

--- Per-object hex: response rewriting.

-- Rewrites every marked variable of a `variables` response, then calls `done`.
--
-- The `,x` evaluation is redone for every response rather than cached: codelldb
-- drops the format it attached to a value as soon as the enclosing scope is
-- fetched again, which dap-ui does on every render, so a reference kept from an
-- earlier render would hand back decimal children. Evaluating from inside the
-- response that the reference is written into keeps the two in step.
local function apply_marks(s, variables, done)
  if vim.tbl_isempty(marks) or not supported(s) then
    return done()
  end

  local targets = {}
  for _, variable in ipairs(variables) do
    if variable.evaluateName and marks[variable.evaluateName] then
      targets[#targets + 1] = variable
    end
  end
  if #targets == 0 then
    return done()
  end

  local frame_id = s.current_frame and s.current_frame.id
  local pending = #targets
  local function finish()
    pending = pending - 1
    if pending == 0 then
      done()
    end
  end

  for _, variable in ipairs(targets) do
    orig_request(s, "evaluate", {
      expression = variable.evaluateName .. ",x",
      frameId = frame_id,
      context = "watch",
    }, function(err, result)
      if not err and type(result) == "table" and result.result then
        variable.value = result.result
        if (result.variablesReference or 0) > 0 then
          variable.variablesReference = result.variablesReference
        end
      end
      finish()
    end)
  end
end

local function record_children(ref, variables)
  if not ref or ref == 0 then
    return
  end
  local by_name = {}
  for _, variable in ipairs(variables) do
    by_name[variable.name] = variable
  end
  children[ref] = by_name
end

local function install()
  local Session = require("dap.session")
  -- Survive a config reload: never wrap an already wrapped request.
  orig_request = Session.__dap_hex_request or Session.request
  Session.__dap_hex_request = orig_request

  Session.request = function(self, command, arguments, on_result)
    if type(on_result) ~= "function" then
      return orig_request(self, command, arguments, on_result)
    end

    if command == "variables" then
      return orig_request(self, command, arguments, function(err, result)
        if err or type(result) ~= "table" or type(result.variables) ~= "table" then
          return on_result(err, result)
        end
        apply_marks(self, result.variables, function()
          record_children(arguments and arguments.variablesReference, result.variables)
          on_result(err, result)
        end)
      end)
    end

    if command == "evaluate" and arguments and arguments.context == "watch" then
      return orig_request(self, command, arguments, function(err, result)
        if not err and type(result) == "table" then
          watch_refs[arguments.expression] = result.variablesReference
        end
        return on_result(err, result)
      end)
    end

    return orig_request(self, command, arguments, on_result)
  end
end

--- Resolving the variable under the cursor in a dap-ui buffer.

-- dap-ui renders a variable as `<indent><icon> <name> <type> = <value>`, where
-- the icon is a single space when the variable has no children. In both cases
-- the name starts two columns after the indent, so the icon's column is the
-- nesting level. Scope headers sit at level 0.
local function parse_var_line(line)
  local icons = require("dapui.config").icons
  local ws, rest = line:match("^(%s*)(.*)$")
  if rest == "" then
    return nil
  end
  for _, icon in ipairs({ icons.expanded, icons.collapsed }) do
    local name = rest:match("^" .. vim.pesc(icon) .. "%s+([^%s]+)")
    if name then
      return name, #ws
    end
  end
  local name = rest:match("^([^%s]+)")
  if not name then
    return nil
  end
  return name, #ws - 2
end

-- Walks up from `lnum` collecting the names of the enclosing variables.
-- Returns them outermost first (the target last) plus the line number of the
-- root line: a scope header in the scopes buffer, a watch expression in the
-- watches buffer.
local function walk_up(lines, lnum)
  local name, indent = parse_var_line(lines[lnum])
  if not name then
    return nil
  end
  if indent <= 0 then
    return {}, lnum
  end

  local names = { name }
  local level = indent
  for i = lnum - 1, 1, -1 do
    local parent, parent_indent = parse_var_line(lines[i])
    if parent and parent_indent < level then
      if parent_indent <= 0 then
        return names, i
      end
      table.insert(names, 1, parent)
      level = parent_indent
    end
  end
  return nil
end

local function descend(ref, names)
  local variable
  for _, name in ipairs(names) do
    local by_name = children[ref]
    if not by_name then
      return nil
    end
    variable = by_name[name]
    if not variable then
      return nil
    end
    ref = variable.variablesReference
  end
  return variable
end

-- The watch a root line belongs to, matched against the registered
-- expressions because an expression may contain spaces.
local function watch_at(line)
  local icons = require("dapui.config").icons
  local rest = line
  for _, icon in ipairs({ icons.expanded, icons.collapsed }) do
    local stripped = rest:match("^" .. vim.pesc(icon) .. "%s+(.*)$")
    if stripped then
      rest = stripped
      break
    end
  end
  local found_index, found
  for index, watch in ipairs(require("dapui").elements.watches.get()) do
    if vim.startswith(rest, watch.expression) then
      if not found or #watch.expression > #found.expression then
        found_index, found = index, watch
      end
    end
  end
  return found_index, found
end

--- Per-object hex: toggling.

-- The expression under the cursor, or the visual selection. dap-ui has its own
-- helper for this, but it is built on nio and only runs inside a task.
local function current_expr()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" then
    return vim.fn.expand("<cexpr>")
  end

  local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
  if from[2] > to[2] or (from[2] == to[2] and from[3] > to[3]) then
    from, to = to, from
  end
  if mode == "V" then
    return table.concat(vim.api.nvim_buf_get_lines(0, from[2] - 1, to[2], false), "\n")
  end

  local last = vim.api.nvim_buf_get_lines(0, to[2] - 1, to[2], false)[1] or ""
  local end_col = math.min(to[3], #last)
  local lines = vim.api.nvim_buf_get_text(0, from[2] - 1, from[3] - 1, to[2] - 1, end_col, {})
  return table.concat(lines, "\n")
end

-- The children of a marked variable are served by the `,x` evaluation, so their
-- `evaluateName` carries that suffix in the middle of the path ("t.hch,x[1]").
-- Strip it, otherwise a mark put on such a child would stop matching anything
-- the moment its parent is unmarked.
local function strip_format_suffix(expr)
  return (expr:gsub(",x([%[%.])", "%1"))
end

local function set_mark(expr, on)
  marks[expr] = on or nil
  notify(("%s: %s"):format(expr, on and "hex" or "default"))
  refresh()
end

local function toggle_mark(expr)
  expr = strip_format_suffix(expr)
  set_mark(expr, not marks[expr])
end

local function variable_by_expr(expr)
  for _, ref in pairs(scope_refs) do
    for _, variable in pairs(children[ref] or {}) do
      if variable.evaluateName == expr or variable.name == expr then
        return variable
      end
    end
  end
end

local function toggle_in_scopes(lines, lnum)
  local names, root = walk_up(lines, lnum)
  if not names or #names == 0 then
    notify("no variable under the cursor", vim.log.levels.WARN)
    return
  end
  local scope = parse_var_line(lines[root])
  local ref = scope and scope_refs[(scope:gsub(":$", ""))]
  local variable = ref and descend(ref, names)
  if not variable or not variable.evaluateName then
    notify("could not resolve the variable under the cursor", vim.log.levels.WARN)
    return
  end
  toggle_mark(variable.evaluateName)
end

local function toggle_in_watches(lines, lnum)
  local names, root = walk_up(lines, lnum)
  if not names then
    notify("no variable under the cursor", vim.log.levels.WARN)
    return
  end

  local index, watch = watch_at(lines[root])
  if not watch then
    notify("could not resolve the watch under the cursor", vim.log.levels.WARN)
    return
  end

  -- On the watch itself, flip the `,x` suffix of the expression: the watch is
  -- an expression of the user's own, not a variable this module can mark.
  if #names == 0 then
    local expr = watch.expression:match("^(.*),x$")
    require("dapui").elements.watches.edit(index, expr or (watch.expression .. ",x"))
    notify(("%s: %s"):format(expr or watch.expression, expr and "default" or "hex"))
    return
  end

  local variable = descend(watch_refs[watch.expression], names)
  if not variable or not variable.evaluateName then
    notify("could not resolve the variable under the cursor", vim.log.levels.WARN)
    return
  end
  toggle_mark(variable.evaluateName)
end

--- Toggles hex display of a single object: the variable under the cursor in the
--- scopes or watches window, or the expression under the cursor (or selected)
--- in a source buffer. An expression that is not a variable of the current
--- frame is added to the watches window in hex instead.
function M.toggle_under_cursor()
  local s = session()
  if not s then
    notify("no active debug session", vim.log.levels.WARN)
    return
  end
  if not supported(s) then
    notify("adapter '" .. tostring(s.config.type) .. "' has no value formats", vim.log.levels.WARN)
    return
  end

  local filetype = vim.bo.filetype
  if filetype == "dapui_scopes" or filetype == "dapui_watches" then
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    if filetype == "dapui_scopes" then
      toggle_in_scopes(lines, lnum)
    else
      toggle_in_watches(lines, lnum)
    end
    return
  end

  local expr = current_expr()
  if not expr or expr == "" then
    notify("no expression under the cursor", vim.log.levels.WARN)
    return
  end

  if marks[expr] then
    set_mark(expr, false)
    return
  end

  local variable = variable_by_expr(expr)
  if variable and variable.evaluateName then
    toggle_mark(variable.evaluateName)
  else
    require("dapui").elements.watches.add(expr .. ",x")
    notify(("%s: watching in hex"):format(expr))
  end
end

function M.setup()
  install()

  local dap = require("dap")
  -- `before` listeners run ahead of the ones dap-ui uses to refresh itself, so
  -- the stale references are gone before anything asks for values again.
  dap.listeners.before.event_stopped.dap_hex = invalidate
  dap.listeners.before.event_continued.dap_hex = invalidate
  dap.listeners.before.event_terminated.dap_hex = invalidate
  dap.listeners.before.event_exited.dap_hex = invalidate

  dap.listeners.after.scopes.dap_hex = function(_, err, response)
    if err or type(response) ~= "table" then
      return
    end
    scope_refs = {}
    for _, scope in ipairs(response.scopes or {}) do
      scope_refs[scope.name] = scope.variablesReference
    end
  end

  -- A session starts at the adapter's own default, so re-apply the chosen
  -- session-wide format to every new session.
  dap.listeners.after.event_initialized.dap_hex = function(s)
    if global_format ~= "auto" and supported(s) then
      apply_global_format(s, global_format)
    end
  end
end

return M
