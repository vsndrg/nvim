-- GoLand-style inline and extract refactorings for Go, offered at the top of
-- the <leader>ca menu of Go buffers (normal and visual mode).
--
--   Inline variable    local `x := e` / `var x = e`: every read of x becomes e
--                      and the declaration goes; from a usage you can also
--                      inline just that usage. A variable that is written
--                      after its declaration is not inlined.
--   Inline constant    the same for a const, across the workspace.
--   Inline function    every call in the workspace, then the declaration
--                      (methods too); from a call, optionally just that call.
--   Extract variable / constant
--                      the visual selection, or in normal mode an expression
--                      picked from the ones around the cursor; asks whether to
--                      replace every occurrence and what to name it.
--   Extract function / method
--                      the selected statements; asks for the name.
--
-- Only declarations inside the workspace are inlined; for a call into the
-- standard library or a dependency the menu keeps gopls's "Inline call".
--
-- gopls does the semantic work: substitution with the right parentheses and
-- the shadowing check (refactor.inline.variable), the call inliner
-- (refactor.inline.call), extraction (refactor.extract.*) and rename. This
-- module finds the targets, checks what gopls does not — a variable that is
-- written, operands of the initializer changing before a use, a call or
-- allocation that would run more than once, later or only conditionally, a
-- constant whose value means something else where it is used — and turns the
-- steps of one refactoring into a single undo step per file. A refactoring
-- stops when a file it works on changes under it.
--
-- TODO: Extract parameter (GoLand "Introduce Parameter"): an expression in a
-- function body becomes a new parameter and every call passes it.
--
--   require("lang.go_refactor").code_action(bufnr)  -- <leader>ca, n and x mode

local go = require("lang.go")

local M = {}

local ns = vim.api.nvim_create_namespace("go_refactor")
local levels = vim.log.levels

local function notify(msg, level)
  vim.notify(msg, level or levels.INFO, { title = "Go refactor" })
end

local function set(words)
  local out = {}
  for word in words:gmatch("%S+") do out[word] = true end
  return out
end

local KEYWORDS = set([[break case chan const continue default defer else
  fallthrough for func go goto if import interface map package range return
  select struct switch type var]])
local BUILTIN_TYPES = set([[any bool byte comparable complex64 complex128 error
  float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16
  uint32 uint64 uintptr]])
local BUILTIN_FUNCS = set([[append cap clear close complex copy delete imag len
  make max min new panic print println real recover]])
-- Builtins whose call has no side effect and returns the same value each time.
local PURE_BUILTINS = set("cap complex imag len max min real")

-- ─────────────────────────────────────────────────────────────────────────────
-- Coroutine plumbing
-- ─────────────────────────────────────────────────────────────────────────────
-- Every refactoring runs as a coroutine: LSP requests, pickers and prompts
-- suspend it with `await` instead of nesting callbacks. (nvim-nio would do,
-- but it keeps every task that started others for good: its child_tasks
-- table is never cleared.)

local Abort = {}

-- Ends the running refactoring; `msg`, if any, tells the user why.
local function abort(msg, level)
  error(setmetatable({ msg = msg, level = level }, Abort), 0)
end

local function report(err)
  if getmetatable(err) == Abort then
    if err.msg then notify(err.msg, err.level or levels.WARN) end
  else
    notify(tostring(err), levels.ERROR)
  end
end

local function traceback(err)
  if getmetatable(err) == Abort then return err end
  return debug.traceback(tostring(err), 2)
end

local resumers = {}

-- Runs `fn` as a coroutine; `finally`, if given, runs when it ends however
-- it ends.
local function async(fn, finally)
  local co
  co = coroutine.create(function()
    xpcall(fn, function(err) report(traceback(err)) end)
    resumers[co] = nil
    if finally then finally() end
  end)
  resumers[co] = function() assert(coroutine.resume(co)) end
  resumers[co]()
end

-- Starts `start(cb)` and suspends until it calls cb; returns cb's arguments.
local function await(start)
  local co = assert(coroutine.running(), "await outside of async")
  local result, suspended = nil, false
  start(function(...)
    if result then return end
    result = vim.F.pack_len(...)
    if suspended then vim.schedule(resumers[co]) end
  end)
  if not result then
    suspended = true
    coroutine.yield()
  end
  return vim.F.unpack_len(result)
end

-- Runs the functions concurrently, each in a coroutine of its own, and returns
-- their results in order. A function that fails is reported and contributes
-- nil.
local function gather(fns)
  if #fns == 0 then return {} end
  return await(function(done)
    local left, out = #fns, {}
    for i, fn in ipairs(fns) do
      async(function()
        local ok, res = xpcall(fn, traceback)
        if ok then out[i] = res else report(res) end
        left = left - 1
        if left == 0 then done(out) end
      end)
    end
  end)
end

local function select(items, opts)
  return await(function(cb) vim.ui.select(items, opts, function(item) cb(item) end) end)
end

local function input(opts)
  return await(function(cb) vim.ui.input(opts, function(text) cb(text) end) end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- LSP, buffers, positions
-- ─────────────────────────────────────────────────────────────────────────────

local function gopls(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })[1]
end

local function changedtick(bufnr)
  return vim.api.nvim_buf_get_changedtick(bufnr)
end

-- A refactoring in progress. `ticks` holds each buffer's changedtick as the
-- refactoring first saw it, then as its own last edit left it: any other
-- value means the positions it computed are stale. `touched` are the buffers
-- it has edited, `marks` its extmarks, deleted when it ends.
local function new_ctx(client, bufnr)
  return { client = client, bufnr = bufnr, ticks = { [bufnr] = changedtick(bufnr) }, touched = {}, marks = {} }
end

local function watch(ctx, bufnr)
  ctx.ticks[bufnr] = ctx.ticks[bufnr] or changedtick(bufnr)
end

local function set_mark(ctx, bufnr, row, col)
  local id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {})
  table.insert(ctx.marks, { bufnr, id })
  return id
end

local function mark_pos(bufnr, id)
  return unpack(vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, {}))
end

local function clear_marks(ctx)
  for _, m in ipairs(ctx.marks) do pcall(vim.api.nvim_buf_del_extmark, m[1], ns, m[2]) end
  ctx.marks = {}
end

-- No buffer is passed on purpose: the client then flushes the pending changes
-- of every buffer, not just one, so gopls never answers from a stale copy of
-- a file this refactoring has just edited. What gopls answers from is what
-- the refactoring works with, so every buffer it knows is watched from here.
local function request(ctx, method, params, client)
  client = client or ctx.client
  for bufnr in pairs(client.attached_buffers) do watch(ctx, bufnr) end
  local err, result = await(function(cb)
    if not client:request(method, params, function(e, r) cb(e, r) end) then
      cb({ message = client.name .. " is not running" })
    end
  end)
  return result, err
end

-- Buffer of a file, loaded but not necessarily shown.
local function file_buf(ctx, uri)
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.bufload(bufnr)
  watch(ctx, bufnr)
  return bufnr
end

-- gopls must track every buffer this module edits, or its next answer would
-- be computed from the file on disk.
local function ensure_attached(bufnr, client)
  if not vim.lsp.buf_is_attached(bufnr, client.id) then vim.lsp.buf_attach_client(bufnr, client.id) end
end

local function buf_line(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

local function lsp_pos(bufnr, row, col, enc)
  return { line = row, character = vim.str_utfindex(buf_line(bufnr, row), enc, col, false) }
end

local function byte_pos(bufnr, pos, enc)
  return pos.line, vim.str_byteindex(buf_line(bufnr, pos.line), enc, pos.character, false)
end

local function lsp_range(bufnr, srow, scol, erow, ecol, enc)
  return { start = lsp_pos(bufnr, srow, scol, enc), ["end"] = lsp_pos(bufnr, erow, ecol, enc) }
end

local function node_lsp_range(bufnr, node, enc)
  local srow, scol, erow, ecol = node:range()
  return lsp_range(bufnr, srow, scol, erow, ecol, enc)
end

local function code_action_params(bufnr, range, only)
  return {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    range = range,
    context = { only = only, diagnostics = {}, triggerKind = 1 },
  }
end

-- The edit of a gopls code action; nil and gopls's reason when there is none.
local function action_edit(ctx, action)
  return go.code_action_edit(function(method, params) return request(ctx, method, params) end, action)
end

local function file_name(bufnr)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
end

local function stale(bufnr, ctx)
  abort(("%s changed while the refactoring was running; stopped%s"):format(file_name(bufnr),
    next(ctx.touched) and " (what it already changed stays: undo reverts it)" or ""))
end

-- { [bufnr] = TextEdit[] } of a WorkspaceEdit; nil if it creates, renames or
-- deletes files. Like core, an edit computed for an older version of a
-- buffer is refused.
local function edits_by_buf(ctx, edit)
  local out = {}
  local function add(uri, edits)
    local bufnr = file_buf(ctx, uri)
    out[bufnr] = vim.list_extend(out[bufnr] or {}, edits)
    return bufnr
  end
  for _, change in ipairs(edit.documentChanges or {}) do
    if change.kind then return nil end
    local bufnr = add(change.textDocument.uri, change.edits)
    local version = change.textDocument.version
    if type(version) == "number" and version > 0 and (vim.lsp.util.buf_versions[bufnr] or 0) > version then
      stale(bufnr, ctx)
    end
  end
  for uri, edits in pairs(edit.changes or {}) do add(uri, edits) end
  return out
end

-- Applies TextEdits, unless the buffer has changed since the refactoring
-- read it. A later change to a buffer the refactoring has already edited
-- joins its undo block, which makes the whole refactoring one undo step per
-- file; the changedtick check keeps that from swallowing an edit of the user.
local function apply_text_edits(ctx, bufnr, edits)
  if ctx.ticks[bufnr] and ctx.ticks[bufnr] ~= changedtick(bufnr) then stale(bufnr, ctx) end
  ensure_attached(bufnr, ctx.client)
  if ctx.touched[bufnr] then
    vim.api.nvim_buf_call(bufnr, function() pcall(vim.cmd.undojoin) end)
  end
  vim.lsp.util.apply_text_edits(edits, bufnr, ctx.client.offset_encoding)
  ctx.touched[bufnr] = true
  ctx.ticks[bufnr] = changedtick(bufnr)
end

local function apply_edit(ctx, edit)
  local per_buf = edits_by_buf(ctx, edit)
  if not per_buf then
    return vim.lsp.util.apply_workspace_edit(edit, ctx.client.offset_encoding)
  end
  for bufnr, edits in pairs(per_buf) do apply_text_edits(ctx, bufnr, edits) end
end

local function organize_imports(ctx, bufnr)
  local edits = go.organize_imports_edits(bufnr, function(method, params) return request(ctx, method, params) end)
  for _, edit in ipairs(edits) do apply_edit(ctx, edit) end
end

-- "a.go, b.go (unsaved)" for the buffers other than the current one.
local function other_files(ctx)
  local names = {}
  for bufnr in pairs(ctx.touched) do
    if bufnr ~= ctx.bufnr then table.insert(names, file_name(bufnr)) end
  end
  table.sort(names)
  if #names == 0 then return "" end
  return ("; also edited %s (unsaved)"):format(table.concat(names, ", "))
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- Whether a declaration of `name` is visible in other packages.
local function exported(name)
  return name:match("^%u") ~= nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Syntax tree
-- ─────────────────────────────────────────────────────────────────────────────

local function tree_root(bufnr)
  return vim.treesitter.get_parser(bufnr, "go"):parse()[1]:root()
end

local function node_at(bufnr, row, col)
  return tree_root(bufnr):named_descendant_for_range(row, col, row, col)
end

local function text_of(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr)
end

local function field(node, name)
  return node and node:field(name)[1]
end

-- Named children without comments: the items of an expression list, the
-- specs of a declaration.
local function items(node, of_type)
  local out = {}
  if not node then return out end
  for child in node:iter_children() do
    if child:named() and child:type() ~= "comment" and (not of_type or child:type() == of_type) then
      table.insert(out, child)
    end
  end
  return out
end

local function same_range(a, b)
  if not (a and b) then return false end
  local a1, a2, a3, a4 = a:range()
  local b1, b2, b3, b4 = b:range()
  return a1 == b1 and a2 == b2 and a3 == b3 and a4 == b4
end

local function contains(outer, inner)
  if not outer then return false end
  local sr, sc, er, ec = outer:range()
  local r1, c1, r2, c2 = inner:range()
  return (sr < r1 or (sr == r1 and sc <= c1)) and (er > r2 or (er == r2 and ec >= c2))
end

local function starts_before(a, b)
  local ar, ac = a:start()
  local br, bc = b:start()
  return ar < br or (ar == br and ac < bc)
end

local function line_of(node) return (node:start()) + 1 end

local function start_byte(node)
  local _, _, byte = node:start()
  return byte
end

local function end_byte(node)
  local _, _, byte = node:end_()
  return byte
end

-- "row:col" of a node's start, to look nodes up by position.
local function key(node)
  local row, col = node:start()
  return row .. ":" .. col
end

local function ancestor(node, types)
  local p = node:parent()
  while p do
    if types[p:type()] then return p end
    p = p:parent()
  end
end

local function ancestors(node, typ)
  local out = {}
  local p = node:parent()
  while p do
    if p:type() == typ then table.insert(out, p) end
    p = p:parent()
  end
  return out
end

local FUNCS = set("function_declaration method_declaration func_literal")
local INITIALIZER_HOLDERS = set("if_statement expression_switch_statement type_switch_statement for_clause")

local function has_descendant(node, typ)
  if node:type() == typ then return true end
  for child in node:iter_children() do
    if child:named() and has_descendant(child, typ) then return true end
  end
  return false
end

-- The identifier an assigned-to expression names: x in x, x.f, x[i], *x, (x).
local function root_ident(node)
  while node do
    local t = node:type()
    if t == "identifier" then return node end
    if t == "selector_expression" or t == "index_expression" or t == "slice_expression"
      or t == "unary_expression" then
      node = field(node, "operand")
    elseif t == "parenthesized_expression" then
      node = items(node)[1]
    else
      return nil
    end
  end
end

-- Expressions whose value a statement changes, or whose address escapes.
-- `:=` counts: it reassigns any variable already declared in that scope.
local WRITE_QUERY = [[
  (assignment_statement left: (expression_list (_) @w))
  (short_var_declaration left: (expression_list (_) @w))
  (inc_statement (_) @w)
  (dec_statement (_) @w)
  (unary_expression operator: "&" operand: (_) @w)
  (range_clause left: (expression_list (_) @w))
]]
local write_query

-- { name, node, ident } for every write inside `scope`.
local function writes_in(bufnr, scope)
  write_query = write_query or vim.treesitter.query.parse("go", WRITE_QUERY)
  local out = {}
  for _, node in write_query:iter_captures(scope, bufnr) do
    local ident = root_ident(node)
    if ident then
      table.insert(out, { name = text_of(ident, bufnr), node = node, ident = ident })
    end
  end
  return out
end

local function is_address_of(node)
  local p = node:parent()
  return p and p:type() == "unary_expression" and field(p, "operator"):type() == "&"
end

-- Whether a value written at `w` can be the one read at `r` for a variable
-- declared by `decl`: plain textual order, plus loops (a write late in the
-- body reaches reads early in the next iteration, unless the declaration
-- itself is in that body) and closures (they run whenever they are called).
local function may_reach(w, r, decl)
  if starts_before(w, r) then return true end
  for _, loop in ipairs(ancestors(r, "for_statement")) do
    if contains(loop, w) and not contains(loop, decl) then return true end
  end
  local wf = ancestors(w, "func_literal")[1]
  if wf and not contains(wf, r) and not contains(wf, decl) then return true end
  local rf = ancestors(r, "func_literal")[1]
  return rf ~= nil and not contains(rf, decl) and not contains(rf, w)
end

-- The semantic token types gopls gives the names in `bufnr`, by "row:col":
-- whether a name is a type or a function is beyond the syntax tree. Asked
-- once per buffer and refactoring, and only when a call needs it.
local function token_types(ctx, bufnr)
  ctx.tokens = ctx.tokens or {}
  if ctx.tokens[bufnr] then return ctx.tokens[bufnr] end
  local out = {}
  local provider = ctx.client.server_capabilities.semanticTokensProvider
  if provider then
    local res = request(ctx, "textDocument/semanticTokens/full", { textDocument = { uri = vim.uri_from_bufnr(bufnr) } })
    local data, names = res and res.data or {}, provider.legend.tokenTypes
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local line, char = 0, 0
    for i = 1, #data, 5 do
      line = line + data[i]
      char = (data[i] == 0 and char or 0) + data[i + 1]
      local col = vim.str_byteindex(lines[line + 1] or "", ctx.client.offset_encoding, char, false)
      out[line .. ":" .. col] = names[data[i + 3] + 1]
    end
  end
  ctx.tokens[bufnr] = out
  return out
end

-- The name a call goes by: f in f(), x.f(), (*T)(p), T[int](v).
local function callee_name(fn)
  local t = fn and fn:type()
  if t == "identifier" or t == "field_identifier" then return fn end
  if t == "selector_expression" then return field(fn, "field") end
  if t == "parenthesized_expression" then return callee_name(items(fn)[1]) end
  if t == "unary_expression" and field(fn, "operator"):type() == "*" then return callee_name(field(fn, "operand")) end
  if t == "index_expression" then return callee_name(field(fn, "operand")) end
end

-- Why evaluating `node` twice differs from evaluating it once, and the part
-- of it responsible; nil when it does not. A conversion looks like a call:
-- gopls tells which is which.
local function impurity(node, bufnr, ctx)
  local t = node:type()
  if t == "func_literal" then return nil end
  if t == "call_expression" then
    local fn = field(node, "function")
    local name = callee_name(fn)
    local text = name and text_of(name, bufnr)
    local builtin = fn:type() == "identifier" and (BUILTIN_TYPES[text] or BUILTIN_FUNCS[text])
    local pure = builtin and (BUILTIN_TYPES[text] or PURE_BUILTINS[text])
    if not builtin and name then
      local kind = token_types(ctx, bufnr)[key(name)]
      pure = kind == "type" or kind == "typeParameter"
    end
    if not pure then return ("calls %s()"):format(text_of(fn, bufnr)), node end
  elseif t == "type_conversion_expression" then
    -- []byte(s) copies the string.
    local typ = field(node, "type")
    if typ:type() == "slice_type" then return ("allocates a new %s"):format(text_of(typ, bufnr)), node end
  elseif t == "unary_expression" then
    local op = field(node, "operator"):type()
    if op == "<-" then return "receives from a channel", node end
    if op == "&" and field(node, "operand"):type() == "composite_literal" then
      return ("allocates %s"):format(text_of(node, bufnr):gsub("%s+", " ")), node
    end
  elseif t == "composite_literal" then
    local typ = field(node, "type")
    if typ and (typ:type() == "slice_type" or typ:type() == "map_type") then
      return ("allocates a new %s"):format(typ:type() == "map_type" and "map" or "slice"), node
    end
  end
  for child in node:iter_children() do
    if child:named() then
      local why, at = impurity(child, bufnr, ctx)
      if why then return why, at end
    end
  end
end

-- The first code with a side effect that runs after byte `from` and before
-- byte `to` inside `node` (closures do not run where they are written):
-- impurity's why and node.
local function impure_between(node, bufnr, from, to, ctx)
  for child in node:iter_children() do
    if child:named() and child:type() ~= "func_literal" and child:type() ~= "comment" then
      local s, e = start_byte(child), end_byte(child)
      if s >= from and e <= to then
        local why, at = impurity(child, bufnr, ctx)
        if why then return why, at end
      elseif e > from and s < to then
        local why, at = impure_between(child, bufnr, from, to, ctx)
        if why then return why, at end
      end
    end
  end
end

local CASES = set("expression_case default_case type_case communication_case")

-- Where `node` runs only under a condition that `decl` does not: a branch
-- of an if or switch, or the right operand of && / ||; nil when it does not.
local function conditional(node, decl)
  local p = node:parent()
  while p and not contains(node, decl) do
    local t = p:type()
    local branch = same_range(field(p, "consequence"), node) or same_range(field(p, "alternative"), node)
    if t == "if_statement" and branch then
      return ("inside the if at line %d"):format(line_of(p))
    end
    if CASES[t] then return ("inside the case at line %d"):format(line_of(p)) end
    if t == "binary_expression" and same_range(field(p, "right"), node) then
      local op = field(p, "operator"):type()
      if op == "&&" or op == "||" then return ("right of %s at line %d"):format(op, line_of(p)) end
    end
    node, p = p, p:parent()
  end
end

local LITERALS = set([[int_literal float_literal imaginary_literal rune_literal
  interpreted_string_literal raw_string_literal true false nil iota]])
local CONSTANT_SHAPES = set("binary_expression unary_expression parenthesized_expression")

-- Literals combined by operators: an untyped constant expression.
local function is_literal_expression(node)
  if LITERALS[node:type()] then return true end
  if not CONSTANT_SHAPES[node:type()] then return false end
  for _, child in ipairs(items(node)) do
    if not is_literal_expression(child) then return false end
  end
  return true
end

-- Comment lines directly above `node`, each on a line of its own: its doc
-- comment. A trailing comment of the line above belongs to that line.
local function doc_start_row(bufnr, node)
  local row = node:start()
  local prev = node:prev_sibling()
  while prev and prev:type() == "comment" and (prev:end_()) == row - 1 do
    local srow, scol = prev:start()
    if not buf_line(bufnr, srow):sub(1, scol):match("^%s*$") then break end
    row = srow
    prev = prev:prev_sibling()
  end
  return row
end

-- An edit deleting `node`: its whole lines (from `from_row`, to drop a doc
-- comment) when nothing but a trailing comment shares them, plus a blank line
-- that would otherwise be doubled or left hanging at the edge of a block.
local function delete_edit(bufnr, node, enc, from_row)
  local srow, scol, erow, ecol = node:range()
  local before = buf_line(bufnr, srow):sub(1, scol)
  local after = buf_line(bufnr, erow):sub(ecol + 1)
  if not (before:match("^%s*$") and (after:match("^%s*$") or after:match("^%s*//"))) then
    return { range = node_lsp_range(bufnr, node, enc), newText = "" }
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  local function blank(row) return row >= 0 and row < count and buf_line(bufnr, row):match("^%s*$") ~= nil end
  local function opens(row) return row < 0 or buf_line(bufnr, row):match("[{(]%s*$") ~= nil end
  local function closes(row) return row >= count or buf_line(bufnr, row):match("^%s*[})]") ~= nil end
  -- Lines [first, stop) go.
  local first, stop = from_row or srow, erow + 1
  if blank(stop) and (blank(first - 1) or opens(first - 1)) then
    stop = stop + 1
  elseif blank(first - 1) and closes(stop) then
    first = first - 1
  end
  if stop < count then
    return { range = lsp_range(bufnr, first, 0, stop, 0, enc), newText = "" }
  end
  -- Through the last line: the newline before goes instead of the one after.
  local last = count - 1
  if first == 0 then
    return { range = lsp_range(bufnr, 0, 0, last, #buf_line(bufnr, last), enc), newText = "" }
  end
  return {
    range = lsp_range(bufnr, first - 1, #buf_line(bufnr, first - 1), last, #buf_line(bufnr, last), enc),
    newText = "",
  }
end

-- An edit deleting item `i` of a comma-separated list, with its separator.
local function list_item_edit(bufnr, list, i, enc)
  local srow, scol, erow, ecol
  if i < #list then
    srow, scol = list[i]:start()
    erow, ecol = list[i + 1]:start()
  else
    srow, scol = list[i - 1]:end_()
    erow, ecol = list[i]:end_()
  end
  return { range = lsp_range(bufnr, srow, scol, erow, ecol, enc), newText = "" }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Scopes
-- ─────────────────────────────────────────────────────────────────────────────
-- Enough of Go's block scoping to tell whether a name written somewhere else
-- still means what it meant where it was written.

local DECL_QUERY = [[
  (short_var_declaration left: (expression_list (identifier) @d))
  (var_spec name: (identifier) @d)
  (const_spec name: (identifier) @d)
  (type_spec name: (type_identifier) @d)
  (parameter_declaration name: (identifier) @p)
  (variadic_parameter_declaration name: (identifier) @p)
  (type_parameter_declaration name: (identifier) @p)
  (range_clause left: (expression_list (identifier) @s))
  (type_switch_statement alias: (expression_list (identifier) @s))
  (receive_statement left: (expression_list (identifier) @s))
]]
local decl_query
local SCOPES = set([[block function_declaration method_declaration func_literal if_statement
  for_statement expression_switch_statement type_switch_statement communication_case]])

-- The local declaration of `name` that is in scope at `site`, or nil. A
-- parameter is in scope in its whole function, any other name from the end
-- of its declaration to the end of the innermost block or statement around it.
local function local_declaration(bufnr, site, name)
  decl_query = decl_query or vim.treesitter.query.parse("go", DECL_QUERY)
  local top = site
  while top:parent() and top:parent():type() ~= "source_file" do top = top:parent() end
  local found
  for id, node in decl_query:iter_captures(top, bufnr) do
    if text_of(node, bufnr) == name then
      local capture = decl_query.captures[id]
      local scope = capture == "p" and ancestor(node, FUNCS) or ancestor(node, SCOPES)
      local stmt = node:parent()
      if stmt:type() == "expression_list" then stmt = stmt:parent() end
      local visible = capture == "p" or end_byte(stmt) <= start_byte(site)
      if scope and visible and contains(scope, site) and (not found or contains(found.scope, scope)) then
        found = { node = node, scope = scope }
      end
    end
  end
  return found and found.node
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Writing an expression somewhere else
-- ─────────────────────────────────────────────────────────────────────────────
-- What keeps an expression meaning the same in another place: parentheses,
-- conversions, and the header of an if, for or switch.

local PRECEDENCE = {
  ["||"] = 1, ["&&"] = 2,
  ["=="] = 3, ["!="] = 3, ["<"] = 3, ["<="] = 3, [">"] = 3, [">="] = 3,
  ["+"] = 4, ["-"] = 4, ["|"] = 4, ["^"] = 4,
  ["*"] = 5, ["/"] = 5, ["%"] = 5, ["<<"] = 5, [">>"] = 5, ["&"] = 5, ["&^"] = 5,
}

local OPERAND_OF = {
  selector_expression = "operand", index_expression = "operand", slice_expression = "operand",
  type_assertion_expression = "operand", call_expression = "function",
}

-- Whether an expression of the given shape ("primary", "unary" or "binary"
-- with precedence `prec`) needs parentheses in place of `target`.
local function needs_parens(shape, prec, target)
  if shape == "primary" then return false end
  local parent = target:parent()
  local pt = parent:type()
  if pt == "binary_expression" then
    local op = field(parent, "operator")
    if shape == "unary" then
      -- Unary operators bind tightest, but written right after a binary
      -- operator they would fuse with it: 2-k must not become 2--1.
      local orow, ocol = op:end_()
      local trow, tcol = target:start()
      return orow == trow and ocol == tcol
    end
    local outer = PRECEDENCE[op:type()]
    return prec < outer or (prec == outer and same_range(field(parent, "right"), target))
  end
  if pt == "unary_expression" then return true end
  return OPERAND_OF[pt] ~= nil and same_range(field(parent, OPERAND_OF[pt]), target)
end

local function shape_of(node)
  local t = node:type()
  if t == "binary_expression" then
    return "binary", PRECEDENCE[field(node, "operator"):type()]
  end
  if t == "unary_expression" then return "unary" end
  return "primary"
end

-- Untyped numeric constants by kind: an operation on two of them has the
-- larger kind of the two, a variable initialized with one the default type.
local NUMERIC_KINDS = { int_literal = 1, rune_literal = 2, float_literal = 3, imaginary_literal = 4 }
local DEFAULT_TYPES = { "int", "rune", "float64", "complex128" }

-- Comparisons and && / ||: their result is a bool whatever the operands.
local function is_comparison(op)
  return PRECEDENCE[op] <= 3
end

-- The kind of an untyped numeric constant expression; nil for any other.
local function numeric_kind(node)
  local t = node:type()
  if NUMERIC_KINDS[t] then return NUMERIC_KINDS[t] end
  if t == "parenthesized_expression" then return numeric_kind(items(node)[1]) end
  if t == "unary_expression" then return numeric_kind(field(node, "operand")) end
  if t == "binary_expression" then
    local op = field(node, "operator"):type()
    if is_comparison(op) then return nil end
    if op == "<<" or op == ">>" then return numeric_kind(field(node, "left")) end
    local l, r = numeric_kind(field(node, "left")), numeric_kind(field(node, "right"))
    return l and r and math.max(l, r)
  end
end

-- Whether an untyped constant of `kind` put in place of `node` would be
-- evaluated in a larger kind than its default type: with n := 3, `n / 2.0`
-- divides ints, `3 / 2.0` floats. Only untyped constant operands do that; a
-- typed one gives the whole expression its type.
local function widened(node, kind)
  local p = node:parent()
  while p do
    local t = p:type()
    if t == "binary_expression" then
      local op = field(p, "operator"):type()
      if is_comparison(op) or op == "<<" or op == ">>" then return false end
      local other = same_range(field(p, "left"), node) and field(p, "right") or field(p, "left")
      local k = is_literal_expression(other) and numeric_kind(other)
      if not k then return false end
      if k > kind then return true end
    elseif t ~= "parenthesized_expression" and t ~= "unary_expression" then
      return false
    end
    node, p = p, p:parent()
  end
  return false
end

-- Types that need parentheses to be converted to: (*T)(v), not *T(v).
local PARENTHESIZED_TYPES = set("pointer_type channel_type function_type")

local function conversion(typ, typ_text, text)
  if PARENTHESIZED_TYPES[typ:type()] then typ_text = "(" .. typ_text .. ")" end
  return ("%s(%s)"):format(typ_text, text)
end

-- Whether `child`, a child of `parent`, is enclosed in parentheses, brackets
-- or braces of `parent`.
local function bracketed(parent, child)
  local t = parent:type()
  if t == "argument_list" or t == "parenthesized_expression" or t == "literal_value" or t == "block" then
    return true
  end
  if t == "index_expression" or t == "slice_expression" then
    return not same_range(field(parent, "operand"), child)
  end
  return t == "type_conversion_expression" and not same_range(field(parent, "type"), child)
end

local TYPE_NAMES = set("type_identifier qualified_type generic_type")

-- Whether `node` contains a composite literal of a named type outside any
-- parentheses, brackets or braces: `Pt{1, 2}`, which the header of an if,
-- for or switch would take for its block.
local function has_bare_composite(node)
  if node:type() == "composite_literal" and TYPE_NAMES[(field(node, "type") or node):type()] then
    return true
  end
  for child in node:iter_children() do
    if child:named() and not bracketed(node, child) and has_bare_composite(child) then return true end
  end
  return false
end

local HEADERS = set("if_statement for_statement expression_switch_statement type_switch_statement")

-- Whether `node` is in the header of an if, for or switch, outside any
-- parentheses, brackets or braces.
local function in_header(node)
  local p = node:parent()
  while p do
    if bracketed(p, node) then return false end
    if HEADERS[p:type()] then return true end
    node, p = p, p:parent()
  end
  return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Inline targets
-- ─────────────────────────────────────────────────────────────────────────────

-- What `name_node` declares, if these refactorings can inline it.
local function declaration_of(name_node)
  local parent = name_node:parent()
  if not parent then return nil end
  local t = parent:type()
  if t == "function_declaration" or t == "method_declaration" then
    if same_range(field(parent, "name"), name_node) then
      return { kind = "function", decl = parent }
    end
  elseif t == "const_spec" or t == "var_spec" then
    for i, n in ipairs(parent:field("name")) do
      if same_range(n, name_node) then
        return {
          kind = t == "const_spec" and "constant" or "variable",
          spec = parent, names = parent:field("name"), index = i,
          values = field(parent, "value") and items(field(parent, "value")),
        }
      end
    end
  elseif t == "expression_list" then
    local decl = parent:parent()
    if decl and decl:type() == "short_var_declaration" and same_range(field(decl, "left"), parent) then
      local names = items(parent)
      for i, n in ipairs(names) do
        if same_range(n, name_node) then
          return {
            kind = "variable", spec = decl, names = names, index = i,
            values = items(field(decl, "right")),
          }
        end
      end
    end
  end
end

local function call_site(node)
  local callee = node
  local p = node:parent()
  if p and p:type() == "selector_expression" and same_range(field(p, "field"), node) then
    callee, p = p, p:parent()
  end
  if p and p:type() == "call_expression" and same_range(field(p, "function"), callee) then
    return p
  end
end

local function in_workspace(client, fname)
  local roots = {}
  for _, folder in ipairs(client.workspace_folders or {}) do
    table.insert(roots, vim.uri_to_fname(folder.uri))
  end
  if #roots == 0 and client.root_dir then roots = { client.root_dir } end
  for _, root in ipairs(roots) do
    if vim.startswith(fname, root .. "/") and not fname:find("/vendor/", #root, true) then
      return true
    end
  end
  return false
end

-- Where the name at (row, col) is declared: uri and LSP position.
local function definition(ctx, bufnr, row, col)
  local res = request(ctx, "textDocument/definition", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = lsp_pos(bufnr, row, col, ctx.client.offset_encoding),
  })
  if res and (res.uri or res.targetUri) then res = { res } end
  local loc = res and res[1]
  if loc then return loc.targetUri or loc.uri, (loc.targetSelectionRange or loc.range).start end
end

-- What declaration_of finds at a definition, plus { name, buf, uri, pos,
-- name_node }; nil outside the workspace, whose files are neither loaded
-- nor edited.
local function workspace_declaration(ctx, uri, pos)
  if not uri or not in_workspace(ctx.client, vim.uri_to_fname(uri)) then return nil end
  local dbuf = file_buf(ctx, uri)
  local name_node = node_at(dbuf, byte_pos(dbuf, pos, ctx.client.offset_encoding))
  local d = name_node and declaration_of(name_node)
  return d and vim.tbl_extend("force", d, {
    name = text_of(name_node, dbuf), buf = dbuf, uri = uri, pos = pos, name_node = name_node,
  })
end

-- The inline target for the identifier at (row, col), or nil:
--   { kind, name, title, buf, uri, pos, name_node, at_decl, ref_node, … }
-- `buf` / `uri` / `pos` / `name_node` locate the declaration; `ref_node` is
-- the identifier under the cursor.
local function inline_target(ctx, row, col)
  local bufnr = ctx.bufnr
  local node = node_at(bufnr, row, col)
  if not node or (node:type() ~= "identifier" and node:type() ~= "field_identifier") then return nil end
  local d = workspace_declaration(ctx, definition(ctx, bufnr, row, col))
  if not d then return nil end
  local t = vim.tbl_extend("force", d, {
    at_decl = d.buf == bufnr and same_range(d.name_node, node), ref_node = node,
  })

  if t.kind == "variable" then
    t.func = ancestor(t.spec, FUNCS)
    if not t.func or not t.values or #t.values ~= #t.names then return nil end
    t.value = t.values[t.index]
    t.title = ('Inline variable "%s"…'):format(t.name)
  elseif t.kind == "constant" then
    if t.values and #t.values ~= #t.names then return nil end
    t.title = ('Inline constant "%s"…'):format(t.name)
  else
    if not t.at_decl and not call_site(node) then return nil end
    t.what = t.decl:type() == "method_declaration" and "method" or "function"
    t.title = ('Inline %s "%s"…'):format(t.what, t.name)
  end
  return t
end

-- "all" or "this", asked when the cursor is on a usage.
local function ask_scope(t, all_label, this_label)
  local pick = select({ "all", "this" }, {
    prompt = t.title:gsub("…$", ""),
    format_item = function(x) return x == "all" and all_label or this_label end,
  })
  if not pick then abort() end
  return pick
end

-- "  line 12: why" lines for the usages left alone, one per usage.
local function reasons(list)
  local lines = {}
  for _, r in ipairs(list) do table.insert(lines, ("  %s: %s"):format(r.where, r.why)) end
  return table.concat(lines, "\n")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Inline variable
-- ─────────────────────────────────────────────────────────────────────────────

-- Whether a name of `t`'s `:=` other than the inlined one declares a new
-- variable rather than assigning one declared before.
local function declares_others(ctx, t)
  local bufnr, enc = t.buf, ctx.client.offset_encoding
  for i, n in ipairs(t.names) do
    if i ~= t.index and text_of(n, bufnr) ~= "_" then
      local row, col = n:start()
      local here = lsp_pos(bufnr, row, col, enc)
      local _, pos = definition(ctx, bufnr, row, col)
      if not pos or (pos.line == here.line and pos.character == here.character) then return true end
    end
  end
  return false
end

local function variable_removal(ctx, t)
  local bufnr, enc, decl = t.buf, ctx.client.offset_encoding, t.spec
  if #t.names > 1 then
    local edits = { list_item_edit(bufnr, t.names, t.index, enc), list_item_edit(bufnr, t.values, t.index, enc) }
    if decl:type() == "short_var_declaration" and not declares_others(ctx, t) then
      -- `x, err := 5, g()` with err declared before: `err = g()`.
      for child in decl:iter_children() do
        if child:type() == ":=" then
          table.insert(edits, { range = node_lsp_range(bufnr, child, enc), newText = "=" })
        end
      end
    end
    return edits
  end
  if decl:type() == "short_var_declaration" then
    local holder = decl:parent()
    if holder and INITIALIZER_HOLDERS[holder:type()] and same_range(field(holder, "initializer"), decl) then
      -- `for n := len(xs); i < n; i++ {` → `for ; i < len(xs); i++ {`
      if holder:type() == "for_clause" then return { { range = node_lsp_range(bufnr, decl, enc), newText = "" } } end
      -- `if x := v; cond {` → `if cond {`
      local semicolon = decl:next_sibling()
      local after = semicolon and semicolon:next_sibling()
      if after then
        local srow, scol = decl:start()
        local erow, ecol = after:start()
        return { { range = lsp_range(bufnr, srow, scol, erow, ecol, enc), newText = "" } }
      end
    end
    return { delete_edit(bufnr, decl, enc) }
  end
  local holder = decl:parent()
  if holder:type() == "var_spec_list" then
    if #items(holder, "var_spec") > 1 then return { delete_edit(bufnr, decl, enc) } end
    holder = holder:parent()
  end
  return { delete_edit(bufnr, holder, enc) }
end

-- The initializer's own source text, re-indented for the line it moves to.
-- gopls prints the expression afresh from column 0 with tab alignment, which
-- mangles multi-line initializers such as composite literals; the source text
-- also keeps the comments inside. Lines within a multi-line raw string are
-- content and stay as they are.
local function moved_text(value, bufnr, target_row)
  local text = text_of(value, bufnr)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 1 then return text end
  local first_row = value:start()
  local verbatim = {}
  local function mark_raw(n)
    if n:type() == "raw_string_literal" then
      local srow, _, erow = n:range()
      for row = srow + 1, erow do verbatim[row] = true end
      return
    end
    for child in n:iter_children() do
      if child:named() then mark_raw(child) end
    end
  end
  mark_raw(value)
  local from = buf_line(bufnr, first_row):match("^%s*")
  local to = buf_line(bufnr, target_row):match("^%s*")
  for i = 2, #lines do
    if not verbatim[first_row + i - 1] and vim.startswith(lines[i], from) then
      lines[i] = to .. lines[i]:sub(#from + 1)
    end
  end
  return table.concat(lines, "\n")
end

-- `w` = { node, method }: an assignment, ++, &x, or a call of a method with
-- a pointer receiver.
local function describe_write(w, name, bufnr)
  local node = w.node
  if w.method then
    return ('"%s" is modified by %s at line %d (pointer receiver)'):format(name, text_of(node, bufnr), line_of(node))
  end
  if is_address_of(node) then
    return ('the address of "%s" is taken at line %d'):format(name, line_of(node))
  end
  local p = node:parent():type()
  if node:type() == "identifier" and p ~= "inc_statement" and p ~= "dec_statement" then
    return ('"%s" is reassigned at line %d'):format(name, line_of(node))
  end
  return ('"%s" is modified at line %d'):format(name, line_of(node))
end

local function inline_variable(ctx, t)
  local bufnr, enc = t.buf, ctx.client.offset_encoding
  local name, decl, value = t.name, t.spec, t.value

  local written = {}
  for _, w in ipairs(writes_in(bufnr, t.func)) do written[key(w.ident)] = w.node end

  -- documentHighlight resolves scopes, so a shadowing `x` elsewhere is not
  -- mistaken for this one; gopls marks assignments as writes (kind 3).
  local highlights = request(ctx, "textDocument/documentHighlight", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = t.pos,
  }) or {}
  local reads, writes = {}, {}
  for _, h in ipairs(highlights) do
    local row, col = byte_pos(bufnr, h.range.start, enc)
    local node = node_at(bufnr, row, col)
    if node and node:type() == "identifier" and not same_range(node, t.name_node) then
      local w = written[key(node)]
      if w or h.kind == 3 then
        table.insert(writes, { node = w or node })
      else
        table.insert(reads, node)
      end
    end
  end

  -- gopls offers to inline a read only where it is a value: not at x.M()
  -- for a method M with a pointer receiver, which takes x's address.
  local actions = gather(vim.tbl_map(function(r)
    return function()
      local params = code_action_params(bufnr, node_lsp_range(bufnr, r, enc), { "refactor.inline.variable" })
      for _, action in ipairs(request(ctx, "textDocument/codeAction", params) or {}) do
        if action.kind == "refactor.inline.variable" then return action end
      end
      return false
    end
  end, reads))
  local usages = {}
  for i, r in ipairs(reads) do
    local p = r:parent()
    if not actions[i] and p:type() == "selector_expression" and same_range(field(p, "operand"), r) then
      table.insert(writes, { node = p, method = true })
    else
      table.insert(usages, { node = r, action = actions[i], where = ("line %d"):format(line_of(r)) })
    end
  end
  -- As in GoLand, a variable that is written is not inlined.
  table.sort(writes, function(a, b) return starts_before(a.node, b.node) end)
  if writes[1] then abort(describe_write(writes[1], name, bufnr) .. "; inline is not possible") end
  if #usages == 0 then abort(('"%s" is never read; nothing to inline'):format(name)) end

  -- gopls substitutes each usage: parentheses where precedence needs them,
  -- and a refusal where a name the initializer uses is shadowed.
  local subs = gather(vim.tbl_map(function(u)
    return function()
      if not u.action then return { why = "gopls offers no inlining here" } end
      local edit, why = action_edit(ctx, u.action)
      local edits = edit and (edits_by_buf(ctx, edit) or {})[bufnr]
      if edits and #edits > 0 then return { edits = edits } end
      return { why = why or "gopls returned no edit" }
    end
  end, usages))
  local n_refused = 0
  for i, u in ipairs(usages) do
    local s = subs[i] or { why = "gopls failed" }
    u.edits, u.why = s.edits, s.why
    if u.why then n_refused = n_refused + 1 end
  end
  if n_refused == #usages then abort(('gopls cannot inline "%s":\n%s'):format(name, reasons(usages)), levels.ERROR) end

  local chosen = usages
  if not t.at_decl and #usages > 1 then
    local here
    for _, u in ipairs(usages) do
      if same_range(u.node, t.ref_node) then here = u end
    end
    if here then
      local all = n_refused == 0 and ("All %d usages, remove the declaration"):format(#usages)
        or ("The %d usages gopls can inline (of %d), keep the declaration"):format(#usages - n_refused, #usages)
      if ask_scope(t, all, ("Only this usage (line %d)"):format(line_of(here.node))) == "this" then
        chosen = { here }
      end
    end
  end
  local inlinable = vim.tbl_filter(function(u) return not u.why end, chosen)
  if #inlinable == 0 then abort(('gopls cannot inline "%s":\n%s'):format(name, reasons(chosen)), levels.ERROR) end

  local issues = {}
  local function issue(u, msg) issues[u] = issues[u] or msg end

  -- Variables the initializer reads; writes to them between the declaration
  -- and a usage change what the inlined expression evaluates to.
  local operands = {}
  local function collect(n)
    if n:type() == "identifier" then operands[text_of(n, bufnr)] = true end
    for child in n:iter_children() do
      if child:named() and child:type() ~= "func_literal" then collect(child) end
    end
  end
  collect(value)
  for _, w in ipairs(writes_in(bufnr, t.func)) do
    local in_closure = ancestors(w.node, "func_literal")[1]
    if operands[w.name] and not contains(decl, w.node)
      and (starts_before(decl, w.node) or (in_closure and not contains(in_closure, decl))) then
      for _, u in ipairs(inlinable) do
        if may_reach(w.node, u.node, decl) then
          issue(u, ("line %d: %s, used by the initializer, changes at line %d")
            :format(line_of(u.node), w.name, line_of(w.node)))
        end
      end
    end
  end

  -- An initializer with side effects (or a fresh allocation) must run as
  -- often as before, and at the same point: once, where it was declared.
  local global
  local why = impurity(value, bufnr, ctx)
  if why then
    local runs = #inlinable + (#inlinable < #usages and 1 or 0)
    if runs > 1 then
      global = ("the initializer %s and would run %d times instead of once"):format(why, runs)
    else
      local u = inlinable[1]
      local r = u.node
      for _, loop in ipairs(ancestors(r, "for_statement")) do
        if not contains(loop, decl) then
          issue(u, ("line %d: the initializer %s and would run on every iteration of the loop at line %d")
            :format(line_of(r), why, line_of(loop)))
          break
        end
      end
      local closure = ancestors(r, "func_literal")[1]
      if closure and not contains(closure, decl) then
        issue(u, ("line %d: the initializer %s and would run each time the closure at line %d is called")
          :format(line_of(r), why, line_of(closure)))
      end
      local before, at = impure_between(t.func, bufnr, end_byte(decl), start_byte(r), ctx)
      if before then
        issue(u, ("line %d: the initializer %s and would run after line %d, which %s")
          :format(line_of(r), why, line_of(at), before))
      end
      local where = conditional(r, decl)
      if where then
        issue(u, ("line %d: the initializer %s and would run only conditionally, %s"):format(line_of(r), why, where))
      end
    end
  end

  local skipped = {}
  if global or next(issues) then
    local lines = { ('Inlining "%s" may change what the code does:'):format(name) }
    if global then table.insert(lines, "  • " .. global) end
    local clean = 0
    for _, u in ipairs(inlinable) do
      if issues[u] then table.insert(lines, "  • " .. issues[u]) else clean = clean + 1 end
    end
    local can_skip = not global and clean > 0
    local buttons = can_skip and "&Inline anyway\n&Skip those usages\n&Cancel" or "&Inline anyway\n&Cancel"
    local choice = vim.fn.confirm(table.concat(lines, "\n"), buttons, can_skip and 3 or 2, "Warning")
    if choice == 0 or choice == (can_skip and 3 or 2) then abort() end
    if choice == 2 then skipped = issues end
  end

  -- `var x int64 = 5`: the literal alone would be an int. `x := 3`: an int,
  -- unless an untyped constant next to the literal makes it a float.
  local typ = decl:type() == "var_spec" and field(decl, "type")
  local literal = is_literal_expression(value)
  local kind = not typ and literal and numeric_kind(value)
  -- gopls's edit tells where the usage is and whether it wanted parentheses;
  -- the text itself comes from the source (see moved_text).
  local source_parens = text_of(value, bufnr):match("^%(") ~= nil
  local shape, prec = shape_of(value)
  local bare_composite = has_bare_composite(value)
  local edits, done = {}, 0
  for _, u in ipairs(inlinable) do
    if not skipped[u] then
      local r = u.node
      local usage = node_lsp_range(bufnr, r, enc)
      for _, e in ipairs(u.edits) do
        if vim.deep_equal(e.range, usage) then
          local text
          if typ and literal then
            text = conversion(typ, text_of(typ, bufnr), text_of(value, bufnr))
          elseif kind and widened(r, kind) then
            text = ("%s(%s)"):format(DEFAULT_TYPES[kind], text_of(value, bufnr))
          else
            text = moved_text(value, bufnr, (r:start()))
            if needs_parens(shape, prec, r) or (e.newText:match("^%(") and not source_parens)
              or (bare_composite and in_header(r)) then
              text = "(" .. text .. ")"
            end
          end
          e = { range = e.range, newText = text }
        end
        table.insert(edits, e)
      end
      done = done + 1
    end
  end
  if done == 0 then abort(('Nothing inlined: every usage of "%s" was skipped'):format(name), levels.INFO) end
  local remove = done == #usages
  if remove then vim.list_extend(edits, variable_removal(ctx, t)) end

  apply_text_edits(ctx, bufnr, edits)

  local msg = ('Inlined "%s": %d of %s'):format(name, done, plural(#usages, "usage"))
  if remove then
    msg = ('Inlined "%s" (%s), declaration removed'):format(name, plural(done, "usage"))
  end
  local refused = vim.tbl_filter(function(u) return u.why ~= nil end, chosen)
  if #refused > 0 then msg = msg .. "; gopls could not inline:\n" .. reasons(refused) end
  notify(msg)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Inline constant
-- ─────────────────────────────────────────────────────────────────────────────

-- The spec whose expression list an implicit spec (`B` under `A = iota`)
-- repeats.
local function governing_spec(spec)
  local prev = spec
  while prev and not field(prev, "value") do
    prev = prev:prev_named_sibling()
    while prev and prev:type() ~= "const_spec" do prev = prev:prev_named_sibling() end
  end
  return prev
end

local function constant_removal(bufnr, t, enc)
  local spec = t.spec
  local decl = spec:parent()
  local specs = items(decl, "const_spec")
  local pos
  for i, s in ipairs(specs) do
    if same_range(s, spec) then pos = i end
  end
  local uses_iota = false
  for _, s in ipairs(specs) do
    if not field(s, "value") or has_descendant(field(s, "value"), "iota") then uses_iota = true end
  end
  local next_spec = specs[pos + 1]
  -- Deleting a spec would renumber the iotas below it, or leave the next spec
  -- without the expression list it repeats: blank the name instead.
  local blank = { { range = node_lsp_range(bufnr, t.name_node, enc), newText = "_" } }
  if next_spec and (uses_iota or not field(next_spec, "value")) then return blank, true end
  if #t.names > 1 then
    if not t.values then return blank, true end
    return { list_item_edit(bufnr, t.names, t.index, enc), list_item_edit(bufnr, t.values, t.index, enc) }
  end
  if #specs > 1 then return { delete_edit(bufnr, spec, enc, doc_start_row(bufnr, spec)) } end
  return { delete_edit(bufnr, decl, enc, doc_start_row(bufnr, decl)) }
end

-- A type name as written in the constant's package, for use elsewhere.
local function qualified_type(typ, qual)
  if not qual or typ:find(".", 1, true) or BUILTIN_TYPES[typ] then return typ end
  if exported(typ) then return qual .. "." .. typ end
end

-- The constant the identifier `node` refers to, if it is declared in the
-- workspace.
local function constant_declaration(ctx, bufnr, node)
  local d = workspace_declaration(ctx, definition(ctx, bufnr, node:start()))
  return d and d.kind == "constant" and d or nil
end

-- The value of constant `c` (as declaration_of describes it) written for the
-- reference `ref`: the expression of its spec, or of the spec an implicit
-- one repeats, converted to the type given there; iota becomes the spec's
-- index. In another package (`ref.qual`) the names of the constant's
-- package are qualified. A constant the value uses that cannot be named at
-- the reference (unexported there, or shadowed) is written out in turn.
-- Returns the text and its shape, or nil and the reason.
local function constant_at(ctx, c, ref, depth)
  local gov = governing_spec(c.spec)
  local value = gov and items(field(gov, "value"))[c.index]
  if not value then return nil, ('cannot find the value of "%s"'):format(c.name) end
  local iota = 0
  for _, s in ipairs(items(c.spec:parent(), "const_spec")) do
    if same_range(s, c.spec) then break end
    iota = iota + 1
  end
  local typ = field(gov, "type")
  if has_descendant(value, "selector_expression") or (typ and typ:type() == "qualified_type") then
    ref.imports = true
  end
  -- The declaration `name` has at the reference, unless it is the one the
  -- constant itself sees.
  local function shadowed(name)
    local d = local_declaration(ref.buf, ref.node, name)
    if d and not (ref.buf == c.buf and same_range(d, local_declaration(c.buf, c.spec, name))) then return d end
  end
  local shape, prec = shape_of(value)
  local subs = {}
  local function walk(n)
    local t = n:type()
    if t == "iota" then
      table.insert(subs, { n, tostring(iota) })
    elseif t == "identifier" or t == "type_identifier" or t == "package_identifier" then
      local p = n:parent()
      local name = text_of(n, c.buf)
      local package = t == "package_identifier"
        or (p:type() == "selector_expression" and same_range(field(p, "operand"), n))
      local d = (package or not ref.qual) and shadowed(name)
      if p:type() == "qualified_type" and not package then
        return -- pkg.T: only the package name is looked up here
      elseif package or BUILTIN_TYPES[name] or BUILTIN_FUNCS[name] then
        if d then return ('"%s" means something else here (line %d)'):format(name, line_of(d)) end
      elseif ref.qual and exported(name) then
        table.insert(subs, { n, ref.qual .. "." .. name })
      elseif d or ref.qual then
        local other = t == "identifier" and depth < 8 and constant_declaration(ctx, c.buf, n)
        local text, why, s, sp
        if other then text, why, s, sp = constant_at(ctx, other, ref, depth + 1) end
        if not text then
          return why or (d and ('"%s" means something else here (line %d)'):format(name, line_of(d))
            or ('"%s" is unexported'):format(name))
        end
        if same_range(n, value) then
          shape, prec = s, sp
        elseif needs_parens(s, sp, n) then
          text = "(" .. text .. ")"
        end
        table.insert(subs, { n, text })
      end
    else
      for child in n:iter_children() do
        if child:named() then
          local why = walk(child)
          if why then return why end
        end
      end
    end
  end
  local why = walk(value)
  if why then return nil, why end

  local base, text = start_byte(value), text_of(value, c.buf)
  table.sort(subs, function(a, b) return start_byte(a[1]) > start_byte(b[1]) end)
  for _, s in ipairs(subs) do
    text = text:sub(1, start_byte(s[1]) - base) .. s[2] .. text:sub(end_byte(s[1]) - base + 1)
  end
  if typ then
    local typ_text = qualified_type(text_of(typ, c.buf), ref.qual)
    if not typ_text then return nil, ("its type %s is unexported"):format(text_of(typ, c.buf)) end
    local d = not ref.qual and typ:type() == "type_identifier" and shadowed(typ_text)
    if d then return nil, ('"%s" means something else here (line %d)'):format(typ_text, line_of(d)) end
    return conversion(typ, typ_text, text), nil, "primary"
  end
  return text, nil, shape, prec
end

local function inline_constant(ctx, t)
  local enc, name = ctx.client.offset_encoding, t.name

  local locations = request(ctx, "textDocument/references", {
    textDocument = { uri = t.uri }, position = t.pos, context = { includeDeclaration = false },
  }) or {}
  if #locations == 0 then abort(('"%s" is never used; nothing to inline'):format(name)) end

  local refs, n_ok = {}, 0
  for _, loc in ipairs(locations) do
    local bufnr = file_buf(ctx, loc.uri)
    local row, col = byte_pos(bufnr, loc.range.start, enc)
    local node = node_at(bufnr, row, col)
    if node then
      local ref = { buf = bufnr, node = node, where = ("%s:%d"):format(file_name(bufnr), row + 1) }
      local p = node:parent()
      if node:type() == "field_identifier" and p:type() == "selector_expression" then
        -- `pkg.Name` from another package: the whole selector goes.
        ref.node, ref.qual = p, text_of(field(p, "operand"), bufnr)
      end
      local text, why, shape, prec = constant_at(ctx, t, ref, 0)
      if text and needs_parens(shape, prec, ref.node) then text = "(" .. text .. ")" end
      ref.text, ref.why = text, why
      if text then n_ok = n_ok + 1 end
      table.insert(refs, ref)
    end
  end
  if n_ok == 0 then abort(('"%s" cannot be inlined:\n%s'):format(name, reasons(refs))) end

  local chosen = refs
  local here
  if not t.at_decl then
    for _, ref in ipairs(refs) do
      if ref.buf == ctx.bufnr and contains(ref.node, t.ref_node) then here = ref end
    end
  end
  if here then
    local all, this
    if #refs > 1 then
      all = n_ok == #refs and ("All %d usages, remove the declaration"):format(#refs)
        or ("The %d usages that can be inlined (of %d), keep the declaration"):format(n_ok, #refs)
      this = ("Only this usage (line %d)"):format(line_of(here.node))
    elseif exported(name) then
      all, this = "Inline and remove the declaration", "Only this usage, keep the declaration"
    end
    if all and ask_scope(t, all, this) == "this" then chosen = { here } end
  end
  local done = vim.tbl_filter(function(ref) return ref.text ~= nil end, chosen)
  if #done == 0 then abort(('"%s" cannot be inlined:\n%s'):format(name, reasons(chosen))) end

  -- Imports change where a `pkg.Name` goes or the value brings a package in.
  local per_buf, imports = {}, {}
  for _, ref in ipairs(done) do
    per_buf[ref.buf] = per_buf[ref.buf] or {}
    table.insert(per_buf[ref.buf], { range = node_lsp_range(ref.buf, ref.node, enc), newText = ref.text })
    if ref.qual or ref.imports then imports[ref.buf] = true end
  end
  local remove, blanked = #done == #refs, false
  if remove then
    local edits
    edits, blanked = constant_removal(t.buf, t, enc)
    per_buf[t.buf] = vim.list_extend(per_buf[t.buf] or {}, edits)
    if refs[1].imports then imports[t.buf] = true end
  end
  for bufnr, edits in pairs(per_buf) do apply_text_edits(ctx, bufnr, edits) end
  for bufnr in pairs(imports) do organize_imports(ctx, bufnr) end

  local msg = ('Inlined "%s": %d of %s'):format(name, #done, plural(#refs, "usage"))
  if remove then
    msg = ('Inlined "%s" (%s), %s'):format(name, plural(#done, "usage"),
      blanked and "name replaced by _ (the specs below depend on it)" or "declaration removed")
  end
  msg = msg .. other_files(ctx)
  local left = vim.tbl_filter(function(ref) return ref.why ~= nil end, chosen)
  if #left > 0 then msg = msg .. "; left alone:\n" .. reasons(left) end
  notify(msg)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Inline function
-- ─────────────────────────────────────────────────────────────────────────────

-- gopls's edit inlining the call whose callee is `node`; nil and gopls's
-- reason when it cannot (e.g. "generic methods not yet supported").
local function inline_call_edit(ctx, bufnr, node, name)
  local params = code_action_params(bufnr, node_lsp_range(bufnr, node, ctx.client.offset_encoding),
    { "refactor.inline.call" })
  for _, action in ipairs(request(ctx, "textDocument/codeAction", params) or {}) do
    if action.kind == "refactor.inline.call" and action.title == "Inline call to " .. name then
      return action_edit(ctx, action)
    end
  end
  return nil, "gopls offers no inlining for this call"
end

local function inline_function(ctx, t)
  local name, enc = t.name, ctx.client.offset_encoding
  local decl_mark = set_mark(ctx, t.buf, t.name_node:start())

  -- The calls among the references to the declaration, and how many
  -- references there are.
  local function references()
    local row, col = mark_pos(t.buf, decl_mark)
    local locations = request(ctx, "textDocument/references", {
      textDocument = { uri = t.uri }, position = lsp_pos(t.buf, row, col, enc),
      context = { includeDeclaration = false },
    }) or {}
    local calls = {}
    for _, loc in ipairs(locations) do
      local bufnr = file_buf(ctx, loc.uri)
      local r, c = byte_pos(bufnr, loc.range.start, enc)
      local node = node_at(bufnr, r, c)
      if node and call_site(node) then table.insert(calls, { buf = bufnr, row = r, col = c }) end
    end
    return calls, #locations
  end

  local calls, total = references()
  local scope = "all"
  if not t.at_decl then
    if #calls > 1 then
      local all = total == #calls and ("All %d calls, remove the declaration"):format(#calls)
        or ("All %d calls, keep the declaration (%s is also used as a value)"):format(#calls, name)
      scope = ask_scope(t, all, ("Only this call (line %d)"):format(line_of(t.ref_node)))
    elseif total == 1 and exported(name) then
      scope = ask_scope(t, "Inline and remove the declaration", "Only this call, keep the declaration")
    end
  end

  if scope == "this" then
    local edit, why = inline_call_edit(ctx, ctx.bufnr, t.ref_node, name)
    if not edit then abort(("gopls cannot inline %s: %s"):format(name, why), levels.ERROR) end
    apply_edit(ctx, edit)
    return
  end

  -- One call at a time: every inlining changes the code around the other
  -- calls, which their extmarks follow; the mark of a call gopls refuses
  -- locates it in the report. An inlined body can bring new calls, and a
  -- call rewritten inside another one's arguments loses its mark, so once
  -- the known calls are done the references are looked up again: a few
  -- rounds at most, for a recursive function.
  local failed, done = {}, 0
  local n_calls = #calls
  for _ = 1, 3 do
    if #calls == 0 then break end
    for _, call in ipairs(calls) do call.mark = set_mark(ctx, call.buf, call.row, call.col) end
    for _, call in ipairs(calls) do
      local row, col = mark_pos(call.buf, call.mark)
      local node = node_at(call.buf, row, col)
      if node and text_of(node, call.buf) == name and call_site(node) then
        local edit, why = inline_call_edit(ctx, call.buf, node, name)
        if edit then
          apply_edit(ctx, edit)
          done = done + 1
        else
          table.insert(failed, { buf = call.buf, mark = call.mark, why = why })
        end
      end
    end
    local refused = {}
    for _, f in ipairs(failed) do
      local row, col = mark_pos(f.buf, f.mark)
      refused[("%d:%d:%d"):format(f.buf, row, col)] = true
    end
    calls, total = references()
    n_calls = #calls
    calls = vim.tbl_filter(function(c) return not refused[("%d:%d:%d"):format(c.buf, c.row, c.col)] end, calls)
  end

  -- "main.go:27, 41: <reason>", one line per distinct reason.
  local lines, by_reason = {}, {}
  for _, f in ipairs(failed) do
    local where = ("%s:%d"):format(file_name(f.buf), mark_pos(f.buf, f.mark) + 1)
    if not by_reason[f.why] then
      by_reason[f.why] = {}
      table.insert(lines, f.why)
    end
    table.insert(by_reason[f.why], where)
  end
  for i, why in ipairs(lines) do lines[i] = ("  %s: %s"):format(table.concat(by_reason[why], ", "), why) end
  if done == 0 and #failed > 0 then
    abort(("gopls cannot inline %s:\n%s"):format(name, table.concat(lines, "\n")), levels.ERROR)
  end

  local msg = ("Inlined %s of %s"):format(plural(done, "call"), name)
  if total == 0 then
    local row, col = mark_pos(t.buf, decl_mark)
    local decl = declaration_of(node_at(t.buf, row, col) or t.name_node)
    if decl and decl.kind == "function" then
      apply_text_edits(ctx, t.buf, { delete_edit(t.buf, decl.decl, enc, doc_start_row(t.buf, decl.decl)) })
      organize_imports(ctx, t.buf)
      msg = msg .. ", declaration removed"
    end
  else
    local kept = {}
    if #failed > 0 then table.insert(kept, plural(#failed, "call") .. " gopls refused") end
    if #calls > 0 then table.insert(kept, plural(#calls, "call") .. " still left") end
    if total > n_calls then table.insert(kept, ("%s of %s as a value"):format(plural(total - n_calls, "use"), name)) end
    msg = msg .. "; declaration kept: " .. table.concat(kept, ", ")
  end
  msg = msg .. other_files(ctx)
  if #lines > 0 then msg = msg .. "\n" .. table.concat(lines, "\n") end
  notify(msg, total == 0 and levels.INFO or levels.WARN)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Names
-- ─────────────────────────────────────────────────────────────────────────────

-- "UserID" → "userID", "URL" → "url", "HTTPServer" → "httpServer".
local function lower_first(s)
  local lead = s:match("^%u+")
  if not lead then return s end
  if #lead == #s then return s:lower() end
  if #lead == 1 then return lead:lower() .. s:sub(2) end
  return lead:sub(1, -2):lower() .. s:sub(#lead)
end

local function singular(s)
  return s:match("^(.-)ies$") and s:sub(1, -4) .. "y" or s:match("^(.-[^s])s$") or s
end

-- GetUser → User, newServer → Server, ParseConfig → Config.
local VERBS = { "Get", "New", "Make", "Load", "Read", "Parse", "Fetch", "Find", "Create", "Build", "Compute", "Calc" }
local function strip_verb(name)
  for _, verb in ipairs(VERBS) do
    local rest = name:match("^" .. verb .. "(%u.*)$") or name:match("^" .. verb:lower() .. "(%u.*)$")
    if rest then return rest end
  end
  return name
end

local NAME_FOR_CALL = {
  len = "n", cap = "c", Sprintf = "s", Sprint = "s", Sprintln = "s", Errorf = "err",
  Join = "s", Itoa = "s", Atoi = "n", ReadAll = "data", Marshal = "data", Now = "now",
  Since = "elapsed", Background = "ctx", TODO = "ctx", WithCancel = "ctx", WithTimeout = "ctx",
}

local NAME_FOR_TYPE = {
  string = "s", int = "n", int64 = "n", int32 = "n", uint = "n", uint64 = "n", uint32 = "n",
  float64 = "f", float32 = "f", bool = "ok", error = "err", byte = "b", rune = "r", any = "v",
}

local function type_name(node, bufnr)
  if not node then return nil end
  local t = node:type()
  if t == "slice_type" or t == "array_type" then
    local el = field(node, "element")
    if el and text_of(el, bufnr) == "byte" then return "data" end
    local n = type_name(el, bufnr)
    return n and #n > 1 and n .. "s" or "items"
  elseif t == "map_type" then
    return "m"
  elseif t == "pointer_type" then
    return type_name(items(node)[1], bufnr)
  elseif t == "channel_type" then
    return "ch"
  elseif t == "qualified_type" then
    return lower_first(text_of(field(node, "name"), bufnr))
  elseif t == "generic_type" then
    return type_name(field(node, "type"), bufnr)
  elseif t == "type_identifier" then
    local s = text_of(node, bufnr)
    return NAME_FOR_TYPE[s] or lower_first(s)
  end
end

-- "max retries" → "maxRetries"
local function words_name(literal)
  local words = {}
  for word in literal:gmatch("%a[%w]*") do
    table.insert(words, #words == 0 and word:lower() or word:sub(1, 1):upper() .. word:sub(2):lower())
    if #words == 3 then break end
  end
  if #words == 0 then return nil end
  return table.concat(words)
end

local BINARY_NAMES = { ["+"] = "sum", ["-"] = "diff", ["*"] = "product", ["/"] = "ratio", ["%"] = "rem" }

-- A GoLand-like name for the value of `node`.
local function suggest(node, bufnr)
  local t = node:type()
  if t == "parenthesized_expression" then return suggest(items(node)[1], bufnr) end
  if t == "call_expression" then
    local fn = field(node, "function")
    local first = items(field(node, "arguments"))[1]
    local fname = (fn:type() == "selector_expression" and text_of(field(fn, "field"), bufnr))
      or (fn:type() == "identifier" and text_of(fn, bufnr))
    if not fname then return nil end
    if NAME_FOR_CALL[fname] then return NAME_FOR_CALL[fname] end
    if fname == "New" and fn:type() == "selector_expression" then
      local pkg = text_of(field(fn, "operand"), bufnr)
      return pkg == "errors" and "err" or lower_first(pkg)
    end
    if (fname == "make" or fname == "new") and first then return type_name(first, bufnr) end
    if (fname == "append" or BUILTIN_TYPES[fname]) and first then return suggest(first, bufnr) end
    return lower_first(strip_verb(fname))
  elseif t == "selector_expression" then
    return lower_first(text_of(field(node, "field"), bufnr))
  elseif t == "index_expression" then
    local op = field(node, "operand")
    local base = (op:type() == "identifier" and text_of(op, bufnr))
      or (op:type() == "selector_expression" and text_of(field(op, "field"), bufnr))
    local one = base and singular(lower_first(base))
    return one ~= lower_first(base or "") and one or "item"
  elseif t == "slice_expression" then
    return suggest(field(node, "operand"), bufnr)
  elseif t == "composite_literal" then
    return type_name(field(node, "type"), bufnr)
  elseif t == "unary_expression" then
    local op = field(node, "operator"):type()
    if op == "!" then return "ok" end
    if op == "<-" then
      local ch = field(node, "operand")
      return ch:type() == "identifier" and singular(text_of(ch, bufnr)) ~= text_of(ch, bufnr)
        and singular(text_of(ch, bufnr)) or "v"
    end
    return suggest(field(node, "operand"), bufnr)
  elseif t == "binary_expression" then
    local op = field(node, "operator"):type()
    if PRECEDENCE[op] <= 3 then return "ok" end
    for _, side in ipairs({ field(node, "left"), field(node, "right") }) do
      if op == "+" and side:type():match("string_literal$") then return "s" end
    end
    return BINARY_NAMES[op]
  elseif t == "interpreted_string_literal" or t == "raw_string_literal" then
    return words_name(text_of(node, bufnr)) or "s"
  elseif t == "int_literal" then
    return "n"
  elseif t == "float_literal" then
    return "f"
  elseif t == "rune_literal" then
    return "r"
  elseif t == "true" or t == "false" then
    return "ok"
  elseif t == "func_literal" then
    return "fn"
  elseif t == "type_assertion_expression" then
    return type_name(field(node, "type"), bufnr)
  elseif t == "type_conversion_expression" then
    return suggest(field(node, "operand"), bufnr) or type_name(field(node, "type"), bufnr)
  elseif t == "identifier" then
    return text_of(node, bufnr)
  end
end

-- Builtins and keywords a suggestion must not shadow or collide with.
local RENAMED = {
  type = "typ", func = "fn", map = "m", range = "rng", select = "sel", default = "def",
  interface = "iface", chan = "ch", package = "pkg", import = "imp", string = "s",
  error = "err", len = "n", copy = "cp", new = "v", make = "v", any = "v", int = "n",
  bool = "ok", byte = "b", rune = "r", cap = "c", min = "lo", max = "hi", real = "re",
  imag = "im", close = "v", delete = "v", print = "v", panic = "v", append = "v",
}

local function suggest_name(node, bufnr, scope)
  local name = node and suggest(node, bufnr) or nil
  name = name and name:gsub("[^%w_]", "") or ""
  if name == "" or name:match("^%d") then name = "v" end
  name = RENAMED[name] or name
  if KEYWORDS[name] or BUILTIN_TYPES[name] or BUILTIN_FUNCS[name] then name = "v" end
  if not scope then return name end
  local taken = {}
  local function collect(n)
    if n:type() == "identifier" then taken[text_of(n, bufnr)] = true end
    for child in n:iter_children() do
      if child:named() then collect(child) end
    end
  end
  collect(scope)
  local candidate, i = name, 1
  while taken[candidate] do
    i = i + 1
    candidate = name .. i
  end
  return candidate
end

-- Asks for a Go identifier; nil when the user cancels.
local function prompt_name(label, default)
  while true do
    local name = input({ prompt = label .. ": ", default = default })
    name = name and vim.trim(name)
    if not name or name == "" then return nil end
    if name:match("^[%a_][%w_]*$") and name ~= "_" and not KEYWORDS[name] then return name end
    notify(("%q is not a valid Go identifier"):format(name), levels.WARN)
    default = name
  end
end


-- ─────────────────────────────────────────────────────────────────────────────
-- Extract
-- ─────────────────────────────────────────────────────────────────────────────

local EXTRACT = {
  variable = { label = "Variable", gen = "newVar" },
  constant = { label = "Constant", gen = "newConst" },
  ["function"] = { label = "Function", gen = "newFunction" },
  method = { label = "Method", gen = "newMethod" },
}

-- { [kind] = action } of the extract actions gopls offers for `range`.
local function extract_actions(ctx, range)
  local params = code_action_params(ctx.bufnr, range, { "refactor.extract" })
  local by_kind = {}
  for _, action in ipairs(request(ctx, "textDocument/codeAction", params) or {}) do
    if action.kind then by_kind[action.kind] = action end
  end
  return by_kind
end

-- Which of our extract operations `acts` allows. gopls offers only "extract
-- constant" for a constant expression; "extract variable" then rewrites its
-- `const c = …` into `c := …`.
local function extract_ops(acts)
  local k = "refactor.extract."
  return {
    variable = acts[k .. "variable"] ~= nil or acts[k .. "constant"] ~= nil,
    constant = acts[k .. "constant"] ~= nil,
    ["function"] = acts[k .. "function"] ~= nil,
    method = acts[k .. "method"] ~= nil,
  }
end

local function word_positions(bufnr, word)
  local out = {}
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local init = 1
    while true do
      local s, e = line:find("%f[%w_]" .. word .. "%f[^%w_]", init)
      if not s then break end
      table.insert(out, { row - 1, s - 1 })
      init = e + 1
    end
  end
  return out
end

-- Renames `gen` as introduced by an extraction, the one occurrence that none
-- of the extmarks `old` (set on the occurrences before it) marks.
local function rename_new(ctx, op, gen, name, old)
  local bufnr = ctx.bufnr
  local before = {}
  for _, id in ipairs(old) do
    local row, col = mark_pos(bufnr, id)
    before[row .. ":" .. col] = true
  end
  local target
  for _, pos in ipairs(word_positions(bufnr, gen)) do
    if not before[pos[1] .. ":" .. pos[2]] then target = pos break end
  end
  if not target then return end
  while true do
    local result, err = request(ctx, "textDocument/rename", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = lsp_pos(bufnr, target[1], target[2], ctx.client.offset_encoding),
      newName = name,
    })
    if result then
      apply_edit(ctx, result)
      return
    end
    notify(("Cannot name it %s: %s"):format(name, err and err.message or "rename failed"), levels.WARN)
    name = prompt_name(EXTRACT[op].label .. " name", name)
    if not name then
      notify(("Kept the name %s"):format(gen))
      return
    end
  end
end

local function run_extract(ctx, op, acts, expr_node)
  local bufnr = ctx.bufnr
  local k = "refactor.extract."
  local base, all, from_const
  if op == "variable" or op == "constant" then
    base, all = acts[k .. op], acts[k .. op .. "-all"]
    if not base and op == "variable" then
      base, all, from_const = acts[k .. "constant"], acts[k .. "constant-all"], true
    end
  else
    base = acts[k .. op]
  end
  if not base then abort() end

  local action = base
  if all then
    local count = tonumber(all.title:match("(%d+) occurrences")) or 2
    local pick = select({ "all", "this" }, {
      prompt = "Extract " .. op,
      format_item = function(x)
        return x == "all" and ("Replace all %d occurrences"):format(count) or "Replace this occurrence only"
      end,
    })
    if not pick then abort() end
    if pick == "all" then action = all end
  end

  -- The edit first: a name asked for an extraction gopls then refuses
  -- would be wasted.
  local edit, err = action_edit(ctx, action)
  if not edit then abort(("gopls: %s"):format(err or "no edit for " .. action.title), levels.ERROR) end
  local per_buf = edits_by_buf(ctx, edit) or {}

  -- The names gopls chose: newVar, or newVar, newVar1 for the two values of
  -- a call.
  local gens, seen = {}, {}
  local pattern = "%f[%w_](" .. (from_const and "newConst" or EXTRACT[op].gen) .. "%d*)%f[^%w_]"
  for _, e in ipairs(per_buf[bufnr] or {}) do
    for gen in e.newText:gmatch(pattern) do
      if not seen[gen] then
        seen[gen] = true
        table.insert(gens, gen)
      end
    end
  end
  if from_const and gens[1] then
    for _, e in ipairs(per_buf[bufnr] or {}) do
      local decl = e.range.start.character == 0 and ("var %s = "):format(gens[1]) or ("%s := "):format(gens[1])
      e.newText = e.newText:gsub("const " .. gens[1] .. " = ", decl)
    end
  end

  -- One name per value; the first is suggested from the expression.
  local suggested = (op == "variable" or op == "constant")
    and suggest_name(expr_node, bufnr, expr_node and ancestor(expr_node, FUNCS)) or ""
  local names = {}
  for i, gen in ipairs(gens) do
    local label = EXTRACT[op].label .. " name" .. (#gens > 1 and (" (%d of %d)"):format(i, #gens) or "")
    names[i] = prompt_name(label, i == 1 and suggested or gen)
    if not names[i] then abort() end
  end

  -- The occurrences of the generated names that exist already, marked to be
  -- told apart from the new ones.
  local old = {}
  for _, gen in ipairs(gens) do
    old[gen] = {}
    for _, pos in ipairs(word_positions(bufnr, gen)) do
      table.insert(old[gen], set_mark(ctx, bufnr, pos[1], pos[2]))
    end
  end
  for b, edits in pairs(per_buf) do apply_text_edits(ctx, b, edits) end
  for i, gen in ipairs(gens) do
    if names[i] ~= gen then rename_new(ctx, op, gen, names[i], old[gen]) end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Expression picker (normal-mode extract)
-- ─────────────────────────────────────────────────────────────────────────────

local EXPRESSIONS = set([[call_expression selector_expression index_expression
  slice_expression binary_expression unary_expression composite_literal
  func_literal type_assertion_expression type_conversion_expression
  interpreted_string_literal raw_string_literal int_literal float_literal
  imaginary_literal rune_literal true false nil]])

-- Statements made of a call, which a variable cannot stand in for.
local CALL_STATEMENTS = set("expression_statement defer_statement go_statement")

local function extractable(node)
  local p = node:parent()
  if not p then return false end
  if CALL_STATEMENTS[p:type()] then return false end
  if p:type() == "call_expression" and same_range(field(p, "function"), node) then return false end
  if p:type() == "inc_statement" or p:type() == "dec_statement" then return false end
  if p:type() == "literal_element" then
    local keyed = p:parent()
    if keyed and keyed:type() == "keyed_element" and same_range(field(keyed, "key"), p) then return false end
  end
  if p:type() == "expression_list" then
    local stmt = p:parent()
    local t = stmt and stmt:type()
    if (t == "assignment_statement" or t == "short_var_declaration" or t == "range_clause")
      and same_range(field(stmt, "left"), p) then
      return false
    end
  end
  return true
end

-- Expressions around (row, col), innermost first, up to the statement.
local function expression_candidates(bufnr, row, col)
  local node = node_at(bufnr, row, col)
  local out = {}
  while node do
    local t = node:type()
    if t == "block" or t == "source_file" or t:match("_statement$") or t:match("_declaration$") then break end
    if EXPRESSIONS[t] and extractable(node) and not (out[#out] and same_range(out[#out], node)) then
      table.insert(out, node)
    end
    node = node:parent()
  end
  return out
end

-- `text` on one line, cut to `max` display cells.
local function one_line(text, max)
  text = text:gsub("%s+", " ")
  if vim.api.nvim_strwidth(text) <= max then return text end
  local n = max - 1
  while vim.api.nvim_strwidth(vim.fn.strcharpart(text, 0, n)) > max - 1 do n = n - 1 end
  return vim.fn.strcharpart(text, 0, n) .. "…"
end

-- Picks one of `candidates` ({ node, label }); the preview shows the code
-- with the expression highlighted, as GoLand does in the editor.
local function pick_expression(bufnr, candidates, title)
  return await(function(cb)
    local ok, pickers = pcall(require, "telescope.pickers")
    if not ok then
      vim.ui.select(candidates, { prompt = title, format_item = function(c) return c.label end },
        function(c) cb(c) end)
      return
    end
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local previewers = require("telescope.previewers")
    local putils = require("telescope.previewers.utils")

    local chosen
    pickers.new(require("telescope.themes").get_dropdown({
      prompt_title = title,
      layout_config = { width = 0.7, height = math.min(#candidates + 4, 12) },
      finder = finders.new_table({
        results = candidates,
        entry_maker = function(c) return { value = c, display = c.label, ordinal = c.label } end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Expression",
        -- One preview buffer for all entries: the code is copied and
        -- highlighted once, then only the expression mark moves.
        get_buffer_by_name = function() return "go_refactor_expression" end,
        define_preview = function(self, entry)
          local pbuf, c = self.state.bufnr, entry.value
          if not self.state.bufname then
            vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
            putils.highlighter(pbuf, "go")
          end
          local srow, scol, erow, ecol = c.node:range()
          vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
          vim.api.nvim_buf_set_extmark(pbuf, ns, srow, scol, { end_row = erow, end_col = ecol, hl_group = "IncSearch" })
          -- Telescope puts the buffer into the preview window on the next tick.
          local winid = self.state.winid
          vim.schedule(function()
            if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= pbuf then return end
            vim.api.nvim_win_set_cursor(winid, { srow + 1, scol })
            vim.api.nvim_win_call(winid, function() vim.cmd("normal! zz") end)
          end)
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          chosen = entry and entry.value
          actions.close(prompt_bufnr)
        end)
        -- Closing the prompt by any means ends the pick; Esc leaves chosen nil.
        vim.api.nvim_create_autocmd("BufWipeout", {
          buffer = prompt_bufnr,
          once = true,
          callback = function() vim.schedule(function() cb(chosen) end) end,
        })
        return true
      end,
    })):find()
  end)
end


-- ─────────────────────────────────────────────────────────────────────────────
-- The menu
-- ─────────────────────────────────────────────────────────────────────────────

-- The visual selection as an end-exclusive byte range; leaves visual mode.
local function take_visual_range(bufnr)
  local mode = vim.api.nvim_get_mode().mode
  if not mode:match("^[vV\22]") then return nil end
  local s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
  local srow, scol, erow, ecol = s[2] - 1, s[3] - 1, e[2] - 1, e[3] - 1
  if srow > erow or (srow == erow and scol > ecol) then
    srow, scol, erow, ecol = erow, ecol, srow, scol
  end
  local last = buf_line(bufnr, erow)
  if mode == "V" or ecol >= #last then
    -- `v$` puts the cursor past the end of the line.
    ecol = #last
  else
    ecol = ecol + 1 + vim.str_utf_end(last, ecol + 1)
  end
  if mode == "V" then scol = 0 end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return { srow, scol, erow, ecol }
end

-- The client's diagnostics on line `row` as the server sent them, which is
-- what vim.lsp.buf.code_action passes along.
local function line_diagnostics(client, bufnr, row)
  local namespaces = { vim.lsp.diagnostic.get_namespace(client.id) }
  local provider = client.server_capabilities.diagnosticProvider
  if provider then
    table.insert(namespaces, vim.lsp.diagnostic.get_namespace(client.id, true, provider.identifier))
  end
  local out = {}
  for _, namespace in ipairs(namespaces) do
    for _, d in ipairs(vim.diagnostic.get(bufnr, { namespace = namespace, lnum = row })) do
      table.insert(out, d.user_data.lsp)
    end
  end
  return out
end

-- Every client's code actions, as { action, client }.
local function native_actions(ctx, range, row)
  local bufnr = ctx.bufnr
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/codeAction" })
  local lists = gather(vim.tbl_map(function(client)
    return function()
      local params = code_action_params(bufnr, lsp_range(bufnr, range[1], range[2], range[3], range[4],
        client.offset_encoding))
      params.context = { triggerKind = 1, diagnostics = line_diagnostics(client, bufnr, row) }
      local actions = request(ctx, "textDocument/codeAction", params, client)
      return vim.tbl_map(function(action) return { action = action, client = client } end, actions or {})
    end
  end, clients))
  local out = {}
  for i = 1, #clients do vim.list_extend(out, lists[i] or {}) end
  return out
end

-- What vim.lsp.buf.code_action does with the chosen action.
local function run_native(ctx, item)
  local action, client = item.action, item.client
  local function apply(a)
    if a.edit then vim.lsp.util.apply_workspace_edit(a.edit, client.offset_encoding) end
    if a.command then
      client:exec_cmd(type(a.command) == "table" and a.command or a, { bufnr = ctx.bufnr, client_id = client.id })
    end
  end
  if type(action.title) == "string" and type(action.command) == "string" then return apply(action) end
  if action.disabled then return notify(action.disabled.reason, levels.ERROR) end
  if not (action.edit and action.command) and client:supports_method("codeAction/resolve") then
    local resolved, err = request(ctx, "codeAction/resolve", action, client)
    if not err then return apply(resolved) end
    -- If resolve fails, the original's edit or command, as core does.
    if action.edit or action.command then return apply(action) end
    return notify(("%s: %s"):format(err.code, err.message), levels.ERROR)
  end
  apply(action)
end

local REPLACED_EXTRACT = set([[refactor.extract.variable refactor.extract.variable-all
  refactor.extract.constant refactor.extract.constant-all refactor.extract.function
  refactor.extract.method]])

local INLINE_RUNNERS = { variable = inline_variable, constant = inline_constant, ["function"] = inline_function }

-- Our entries for normal mode: inline for the identifier under the cursor,
-- extract for the expressions around it. To build the menu gopls is asked
-- about the innermost expression only, or the next ones out while it offers
-- nothing; the others are asked once "Extract …" is chosen. So "Extract
-- constant…" shows when the first extractable expression is a constant one,
-- which is the case whenever any of them is, save the rare constant made of
-- non-constant parts (len of an array).
local function normal_entries(ctx, row, col)
  local candidates = {}
  for i, node in ipairs(expression_candidates(ctx.bufnr, row, col)) do
    if i > 8 then break end
    table.insert(candidates, { node = node, label = one_line(text_of(node, ctx.bufnr), 70) })
  end
  local function ask(c)
    c.acts = c.acts or extract_actions(ctx, node_lsp_range(ctx.bufnr, c.node, ctx.client.offset_encoding))
    c.ops = extract_ops(c.acts)
    return c.ops
  end
  local results = gather({
    function() return inline_target(ctx, row, col) end,
    function()
      for _, c in ipairs(candidates) do
        if ask(c).variable then return c.ops end
      end
    end,
  })

  local entries, t, first = {}, results[1], results[2]
  if t then
    table.insert(entries, { title = t.title, inline = t, run = function() INLINE_RUNNERS[t.kind](ctx, t) end })
  end
  for _, op in ipairs({ "variable", "constant" }) do
    if first and first[op] then
      table.insert(entries, {
        title = ("Extract %s…"):format(op),
        run = function()
          gather(vim.tbl_map(function(c) return function() ask(c) end end, candidates))
          local usable = vim.tbl_filter(function(c) return c.ops and c.ops[op] end, candidates)
          local c = #usable == 1 and usable[1] or pick_expression(ctx.bufnr, usable, "Extract " .. op)
          if not c then abort() end
          run_extract(ctx, op, c.acts, c.node)
        end,
      })
    end
  end
  return entries
end

-- Our entries for visual mode: extract what the selection covers.
local function visual_entries(ctx, range, natives)
  local acts = {}
  for _, item in ipairs(natives) do
    if item.client.id == ctx.client.id and item.action.kind then acts[item.action.kind] = item.action end
  end
  local node = tree_root(ctx.bufnr):named_descendant_for_range(unpack(range))
  local srow, scol, erow, ecol = node:range()
  local exact = srow == range[1] and scol == range[2] and erow == range[3] and ecol == range[4]
  local entries = {}
  for _, op in ipairs({ "variable", "constant", "function", "method" }) do
    local expression = op == "variable" or op == "constant"
    if extract_ops(acts)[op] and not (expression and exact and not extractable(node)) then
      table.insert(entries, {
        title = ("Extract %s…"):format(op),
        run = function() run_extract(ctx, op, acts, exact and node or nil) end,
      })
    end
  end
  return entries
end

function M.code_action(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local client = gopls(bufnr)
  local ok_parser = pcall(vim.treesitter.get_parser, bufnr, "go")
  if not client or not ok_parser then return vim.lsp.buf.code_action() end

  local range = take_visual_range(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  range = range or { row, col, row, col }
  local ctx = new_ctx(client, bufnr)

  async(function()
    local natives, ours
    if range[1] == range[3] and range[2] == range[4] then
      local results = gather({
        function() return native_actions(ctx, range, row) end,
        function() return normal_entries(ctx, row, col) end,
      })
      natives, ours = results[1] or {}, results[2] or {}
    else
      natives = native_actions(ctx, range, row)
      ours = visual_entries(ctx, range, natives)
    end

    -- gopls's own versions of what our entries do.
    local inline = ours[1] and ours[1].inline
    local function replaced(item)
      if item.client.id ~= client.id then return false end
      local kind = item.action.kind
      if REPLACED_EXTRACT[kind] then return true end
      if inline and inline.kind == "variable" and kind == "refactor.inline.variable" then return true end
      return inline and inline.kind == "function" and kind == "refactor.inline.call"
        and item.action.title == "Inline call to " .. inline.name
    end
    -- Entries have the shape vim.lsp.buf.code_action hands to vim.ui.select
    -- ({ action, ctx }): pickers such as telescope-ui-select render kind
    -- "codeaction" from those fields and ignore format_item.
    local menu = {}
    for _, entry in ipairs(ours) do
      table.insert(menu, {
        action = { title = entry.title },
        ctx = { client_id = client.id, bufnr = bufnr },
        run = entry.run,
      })
    end
    for _, item in ipairs(natives) do
      if not replaced(item) then
        table.insert(menu, { action = item.action, ctx = { client_id = item.client.id, bufnr = bufnr }, native = item })
      end
    end
    if #menu == 0 then
      notify("No code actions available")
      return
    end

    local several = #vim.lsp.get_clients({ bufnr = bufnr }) > 1
    local choice = select(menu, {
      prompt = "Code actions:",
      kind = "codeaction",
      format_item = function(entry)
        local title = entry.action.title:gsub("\r?\n", "\\n")
        if entry.action.disabled then title = title .. " (disabled)" end
        if several then
          title = ("%s [%s]"):format(title, vim.lsp.get_client_by_id(entry.ctx.client_id).name)
        end
        return title
      end,
    })
    if not choice then return end
    if choice.native then
      run_native(ctx, choice.native)
    else
      choice.run()
    end
  end, function() clear_marks(ctx) end)
end

return M
