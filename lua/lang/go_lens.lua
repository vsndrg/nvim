-- GoLand-style code vision for Go buffers, drawn at the end of the
-- declaration line:
--   3 usages              references to a type / function / method / var;
--   ↓ 3 impl              on an interface and on each of its methods;
--   ↑ Shape, fmt.Stringer on a concrete type / method that implements them.
-- Every underlined word is clickable. `gi` jumps to the ↓ / ↑ targets of the
-- cursor line, `gu` to its usages: one target is opened directly, several go
-- to a Telescope picker.
--
-- Everything comes from gopls: textDocument/documentSymbol finds the
-- declarations, textDocument/references counts usages,
-- textDocument/implementation answers "implementations" for interfaces and
-- "implemented interfaces" for concrete types, and documentSymbol of each
-- target file names the interfaces behind the ↑ locations.
--
--   require("lang.go_lens").setup()        -- highlights + cross-buffer refresh
--   require("lang.go_lens").attach(bufnr)  -- on gopls LspAttach
--   require("lang.go_lens").open(bufnr)    -- ↓ / ↑ targets for the cursor line
--   require("lang.go_lens").usages(bufnr)  -- usages for the cursor line

local M = {}

local ns = vim.api.nvim_create_namespace("go_lens")
local group = vim.api.nvim_create_augroup("GoLens", { clear = true })

local Kind = vim.lsp.protocol.SymbolKind
local DEBOUNCE_MS = 500
-- Interface names listed in an ↑ marker before it collapses into "+N".
local MAX_NAMES = 3
-- Blank cells between the code and the marker and between the marker's
-- parts. Neovim itself leaves one cell before eol virtual text; the rest is
-- padding, so both gaps come out the same width.
local GAP = 2

local TITLES = {
  usages = "Usages",
  down   = "Implementations",
  up     = "Implemented interfaces",
  both   = "Implementations / interfaces",
}

-- Declarations whose usages are counted. Fields and interface methods are
-- left out, as in GoLand.
local USAGE_KINDS = {
  [Kind.Interface] = true, [Kind.Struct] = true, [Kind.Class] = true,
  [Kind.Function] = true, [Kind.Method] = true,
  [Kind.Variable] = true, [Kind.Constant] = true,
}

-- [bufnr] = {
--   gen     = number,             -- bumped by every refresh; older replies drop
--   pending = { request_id... },  -- in-flight gopls requests of this gen
--   targets = { [extmark_id] = { kind, locations, usages, segments } },
--   timer   = uv_timer,
--   stale   = bool,               -- another Go file was saved while hidden
-- }
local state = {}

local function gopls(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })[1]
end

local function cancel_pending(st, client)
  for _, id in ipairs(st.pending) do
    pcall(client.cancel_request, client, id)
  end
  st.pending = {}
end

-- Nothing can reference these: the blank identifier, init, and the functions
-- `go test` calls by name.
local function unreferenceable(sym, is_test_file)
  if sym.name == "_" or sym.name == "init" then return true end
  return is_test_file and sym.kind == Kind.Function
    and (sym.name:match("^Test") or sym.name:match("^Benchmark")
      or sym.name:match("^Fuzz") or sym.name:match("^Example")) ~= nil
end

-- What to ask about each declaration: "usages" → references, "down" / "up" →
-- implementation, with the direction its answer means. Fields, functions and
-- embedded interfaces have no implementation relation.
local function collect_queries(symbols, is_test_file)
  local queries = {}
  local function add(sym, what)
    table.insert(queries, { pos = sym.selectionRange.start, what = what })
  end
  for _, sym in ipairs(symbols) do
    if sym.selectionRange then
      if USAGE_KINDS[sym.kind] and not unreferenceable(sym, is_test_file) then
        add(sym, "usages")
      end
      if sym.kind == Kind.Interface then
        add(sym, "down")
        for _, child in ipairs(sym.children or {}) do
          if child.kind == Kind.Method then add(child, "down") end
        end
      elseif sym.kind == Kind.Struct or sym.kind == Kind.Class or sym.kind == Kind.Method then
        add(sym, "up")
      end
    end
  end
  return queries
end

-- textDocument/implementation may answer Location, Location[] or LocationLink[].
local function as_list(result)
  if not result then return {} end
  if result.uri or result.targetUri then return { result } end
  return result
end

local function loc_uri(loc) return loc.uri or loc.targetUri end
local function loc_start(loc) return (loc.targetSelectionRange or loc.range).start end

local function location_key(loc)
  local start = loc_start(loc)
  return ("%s:%d:%d"):format(loc_uri(loc), start.line, start.character)
end

local function before_or_at(a, b)
  return a.line < b.line or (a.line == b.line and a.character <= b.character)
end

-- Top-level declaration of `symbols` that encloses `pos`: the interface itself
-- for a type-level target, the interface owning the method for a method one.
local function enclosing_name(symbols, pos)
  for _, sym in ipairs(symbols or {}) do
    local range = sym.range or (sym.location and sym.location.range)
    if range and before_or_at(range.start, pos) and before_or_at(pos, range["end"]) then
      return sym.name
    end
  end
  return nil
end

-- "Shape" for the buffer's own package, "fmt.Stringer" for another one, nil
-- for an unexported interface of another package (runtime.stringer and the
-- like): user code cannot name it, so it is only noise in the marker and the
-- picker.
local function qualified_name(name, uri, own_dir)
  local dir = vim.fs.dirname(vim.uri_to_fname(uri))
  if dir == own_dir then return name end
  if not name:match("^%u") then return nil end
  return vim.fs.basename(dir) .. "." .. name
end

local function plural(n, word)
  if n == 0 then return "no " .. word .. "s" end
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- Segments of one line's marker, left to right. A segment with `locations`
-- is a link: underlined and clickable.
local function segments_of(entry)
  local segs = {}
  local function text(t) table.insert(segs, { text = t, hl = "GoLens" }) end
  local function link(t, locations, title)
    table.insert(segs, { text = t, hl = "GoLensLink", locations = locations, title = title })
  end
  local function gap() if #segs > 0 then text(string.rep(" ", GAP)) end end

  if entry.usages then
    if #entry.usages == 0 then
      text(plural(0, "usage"))
    else
      link(plural(#entry.usages, "usage"), entry.usages, TITLES.usages)
    end
  end
  if #entry.down > 0 then
    gap()
    text("↓ ")
    link(("%d impl"):format(#entry.down), entry.down, TITLES.down)
  end
  if #entry.up_groups > 0 then
    gap()
    text("↑ ")
    for i = 1, math.min(#entry.up_groups, MAX_NAMES) do
      if i > 1 then text(", ") end
      local grp = entry.up_groups[i]
      link(grp.name, grp.locations, TITLES.up)
    end
    if #entry.up_groups > MAX_NAMES then
      text(", ")
      link(("+%d"):format(#entry.up_groups - MAX_NAMES), entry.up, TITLES.up)
    end
  end
  return segs
end

local function render(bufnr, lines)
  local st = state[bufnr]
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  st.targets = {}
  for line, entry in pairs(lines) do
    local segs = segments_of(entry)
    if #segs > 0 then
      local chunks, offset = { { string.rep(" ", GAP - 1), "GoLens" } }, 0
      for _, seg in ipairs(segs) do
        seg.start = offset
        seg.width = vim.fn.strdisplaywidth(seg.text)
        offset = offset + seg.width
        table.insert(chunks, { seg.text, seg.hl })
      end
      local locations = vim.list_extend(vim.list_extend({}, entry.down), entry.up)
      local kind = (#entry.down > 0 and #entry.up > 0) and "both" or (#entry.down > 0 and "down" or "up")
      local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
        virt_text = chunks,
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
      if ok then
        st.targets[id] = { kind = kind, locations = locations, usages = entry.usages, segments = segs }
      end
    end
  end
end

function M.refresh(bufnr)
  local st = state[bufnr]
  local client = gopls(bufnr)
  if not st or not client or not vim.api.nvim_buf_is_loaded(bufnr) then return end

  cancel_pending(st, client)
  st.gen = st.gen + 1
  st.stale = false
  local gen = st.gen
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  -- Positions from gopls describe the text at `tick`; once the buffer moved
  -- on, the debounced refresh scheduled by that edit takes over.
  local function current()
    return state[bufnr] == st and st.gen == gen
      and vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_buf_get_changedtick(bufnr) == tick
  end
  local function request(method, params, handler)
    local ok, id = client:request(method, params, function(err, result)
      if current() then handler(err, result) end
    end, bufnr)
    if ok then table.insert(st.pending, id) end
    return ok
  end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  local own_dir = vim.fs.dirname(fname)
  local lines = {}
  local function entry_at(line)
    lines[line] = lines[line] or { down = {}, up = {}, up_groups = {}, seen = {} }
    return lines[line]
  end

  -- Phase 2: name the interfaces behind every ↑ location, one documentSymbol
  -- request per target file.
  local function resolve_names()
    local by_uri = {}
    for _, entry in pairs(lines) do
      for _, loc in ipairs(entry.up) do
        by_uri[loc_uri(loc)] = true
      end
    end
    local symbols_of = {}
    local remaining = vim.tbl_count(by_uri)

    local function finish()
      for _, entry in pairs(lines) do
        local kept, groups, by_name = {}, {}, {}
        for _, loc in ipairs(entry.up) do
          local name = enclosing_name(symbols_of[loc_uri(loc)], loc_start(loc))
          name = name and qualified_name(name, loc_uri(loc), own_dir)
          if name then
            table.insert(kept, loc)
            if not by_name[name] then
              by_name[name] = { name = name, locations = {} }
              table.insert(groups, by_name[name])
            end
            table.insert(by_name[name].locations, loc)
          end
        end
        entry.up, entry.up_groups = kept, groups
      end
      render(bufnr, lines)
    end

    if remaining == 0 then return finish() end
    for uri in pairs(by_uri) do
      local sent = request("textDocument/documentSymbol", { textDocument = { uri = uri } }, function(err, result)
        symbols_of[uri] = not err and result or nil
        remaining = remaining - 1
        if remaining == 0 then finish() end
      end)
      if not sent then remaining = remaining - 1 end
    end
    if remaining == 0 then finish() end
  end

  -- Phase 1: declarations of this buffer, their usages, and what implements /
  -- is implemented by each of them.
  local text_document = vim.lsp.util.make_text_document_params(bufnr)
  request("textDocument/documentSymbol", { textDocument = text_document }, function(err, symbols)
    if err or not symbols then return end
    st.pending = {}

    local queries = collect_queries(symbols, fname:match("_test%.go$") ~= nil)
    local remaining = #queries
    if remaining == 0 then return render(bufnr, lines) end

    local function done()
      remaining = remaining - 1
      if remaining == 0 then resolve_names() end
    end

    for _, query in ipairs(queries) do
      local sent
      if query.what == "usages" then
        local params = {
          textDocument = text_document,
          position = query.pos,
          context = { includeDeclaration = false },
        }
        sent = request("textDocument/references", params, function(ref_err, result)
          -- A failed query shows nothing rather than a wrong "no usages".
          if not ref_err then entry_at(query.pos.line).usages = result or {} end
          done()
        end)
      else
        local params = { textDocument = text_document, position = query.pos }
        sent = request("textDocument/implementation", params, function(impl_err, result)
          local locations = impl_err and {} or as_list(result)
          if #locations > 0 then
            local entry = entry_at(query.pos.line)
            for _, loc in ipairs(locations) do
              local key = location_key(loc)
              if not entry.seen[key] then
                entry.seen[key] = true
                table.insert(entry[query.what], loc)
              end
            end
          end
          done()
        end)
      end
      if not sent then remaining = remaining - 1 end
    end
    if remaining == 0 then resolve_names() end
  end)
end

local function schedule_refresh(bufnr)
  local st = state[bufnr]
  if not st then return end
  st.timer:stop()
  st.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function() M.refresh(bufnr) end))
end

local function detach(bufnr)
  local st = state[bufnr]
  if not st then return end
  local client = gopls(bufnr)
  if client then cancel_pending(st, client) end
  st.timer:stop()
  st.timer:close()
  state[bufnr] = nil
  pcall(vim.api.nvim_clear_autocmds, { group = group, buffer = bufnr })
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Navigation
-- ─────────────────────────────────────────────────────────────────────────────

-- Shortest trailing part of each path that no other path in the list shares:
-- "model_test.go" alone, "lru/cache.go" vs "lfu/cache.go" when they clash.
local function short_names(paths)
  local parts, names = {}, {}
  for _, path in ipairs(paths) do parts[path] = vim.split(path, "/", { plain = true }) end
  for _, path in ipairs(paths) do
    local p = parts[path]
    for k = 1, #p do
      local suffix = table.concat(p, "/", #p - k + 1)
      local clash = false
      for _, other in ipairs(paths) do
        if other ~= path and (other == suffix or vim.endswith(other, "/" .. suffix)) then
          clash = true
          break
        end
      end
      if not clash or k == #p then
        names[path] = suffix
        break
      end
    end
  end
  return names
end

-- Treesitter highlights of row `row` of `filename`, parsed as a whole file so
-- a lone line like `c.Put(i, i)` gets the colours it has in the editor.
-- Ranges are byte columns into the line; one parse per file per picker.
local function line_highlighter()
  local files = {}
  local query = vim.F.npcall(vim.treesitter.query.get, "go", "highlights")

  local function parsed(filename)
    if files[filename] == nil then
      local bufnr = vim.fn.bufnr(filename)
      local lines = bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)
        and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        or vim.F.npcall(vim.fn.readfile, filename) or {}
      local text = table.concat(lines, "\n")
      local parser = vim.F.npcall(vim.treesitter.get_string_parser, text, "go")
      local tree = parser and parser:parse()[1]
      files[filename] = tree and { root = tree:root(), text = text, lines = lines } or false
    end
    return files[filename]
  end

  return function(filename, row)
    local file = query and parsed(filename)
    if not file then return {} end
    local len = #(file.lines[row + 1] or "")
    local ranges = {}
    for id, node in query:iter_captures(file.root, file.text, row, row + 1) do
      local name = query.captures[id]
      if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" then
        local sr, sc, er, ec = node:range()
        if sr < row then sc = 0 end
        if er > row then ec = len end
        if ec > sc then table.insert(ranges, { sc, ec, "@" .. name .. ".go" }) end
      end
    end
    return ranges
  end
end

-- Telescope entries laid out as "file.go:42  <code>": the file column is as
-- wide as the longest short name, and the code keeps its syntax colours.
local function entry_maker(items)
  local paths, seen = {}, {}
  for _, item in ipairs(items) do
    if not seen[item.filename] then
      seen[item.filename] = true
      table.insert(paths, item.filename)
    end
  end
  local names = short_names(paths)
  local width = 0
  for _, item in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(names[item.filename] .. ":" .. item.lnum))
  end

  local displayer = require("telescope.pickers.entry_display").create({
    separator = "  ",
    items = { { width = width }, { remaining = true } },
  })
  local highlights_of = line_highlighter()

  return function(item)
    local name = names[item.filename]
    local code = item.text:gsub("^%s+", "")
    local indent = #item.text - #code
    return {
      value = item,
      ordinal = name .. " " .. code,
      filename = item.filename,
      lnum = item.lnum,
      col = item.col,
      text = code,
      display = function()
        return displayer({
          { name .. ":" .. item.lnum, function()
            return { { { #name, #name + 1 + #tostring(item.lnum) }, "TelescopeResultsLineNr" } }
          end },
          { code, function()
            local hls = {}
            for _, r in ipairs(highlights_of(item.filename, item.lnum - 1)) do
              local from, to = math.max(r[1] - indent, 0), math.min(r[2] - indent, #code)
              if to > from then table.insert(hls, { { from, to }, r[3] }) end
            end
            return hls
          end },
        })
      end,
    }
  end
end

local function show(locations, encoding, title)
  if #locations == 1 then
    vim.lsp.util.show_document(locations[1], encoding, { focus = true, reuse_win = true })
    vim.cmd("normal! zz")
    return
  end

  local items = vim.lsp.util.locations_to_items(locations, encoding)
  local ok = pcall(function()
    local conf = require("telescope.config").values
    require("telescope.pickers").new({}, {
      prompt_title = title,
      -- A handful of targets is picked with j/k, not by typing.
      initial_mode = "normal",
      finder = require("telescope.finders").new_table({
        results = items,
        entry_maker = entry_maker(items),
      }),
      previewer = conf.qflist_previewer({}),
      sorter = conf.generic_sorter({}),
      push_cursor_on_edit = true,
      push_tagstack_on_edit = true,
    }):find()
  end)
  if not ok then
    vim.fn.setqflist({}, " ", { title = title, items = items })
    vim.cmd("botright copen")
  end
end

-- Marker on `row` (0-based) of the buffer, or nil.
local function marker_on(bufnr, row)
  local st = state[bufnr]
  if not st then return nil end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, {})
  for _, mark in ipairs(marks) do
    local entry = st.targets[mark[1]]
    if entry then return entry end
  end
  return nil
end

-- Shared by `gi` and `gu`: the cursor line's marker answers first, so both
-- keys work from anywhere on a declaration line; a line without an answer
-- in its marker asks gopls about the symbol under the cursor, so a call site
-- like `s.Area()` works too.
local function open_at_cursor(bufnr, from_marker, method, context, title, empty_msg)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local client = gopls(bufnr)
  if not client then
    vim.notify("gopls is not attached", vim.log.levels.WARN)
    return
  end

  local entry = marker_on(bufnr, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if entry then
    local locations, marker_title = from_marker(entry)
    if locations and #locations > 0 then
      show(locations, client.offset_encoding, marker_title)
      return
    end
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = context
  client:request(method, params, function(err, result)
    local locations = err and {} or as_list(result)
    if #locations == 0 then
      vim.notify(empty_msg, vim.log.levels.INFO)
      return
    end
    show(locations, client.offset_encoding, title)
  end, bufnr)
end

-- ↓ / ↑ targets (`gi`).
function M.open(bufnr)
  open_at_cursor(bufnr, function(entry) return entry.locations, TITLES[entry.kind] end,
    "textDocument/implementation", nil, TITLES.down, "No implementations found")
end

-- Usages without the declaration itself, as counted in the marker (`gu`).
function M.usages(bufnr)
  open_at_cursor(bufnr, function(entry) return entry.usages, TITLES.usages end,
    "textDocument/references", { includeDeclaration = false }, TITLES.usages, "No usages found")
end

-- <LeftMouse> on an underlined word of a marker opens what it names, like
-- clicking Code Vision in GoLand. Every click keeps its default behaviour as
-- well.
local function on_click()
  local pos = vim.fn.getmousepos()
  if pos.winid == 0 or pos.line == 0 then return "<LeftMouse>" end
  local bufnr = vim.api.nvim_win_get_buf(pos.winid)
  local entry = marker_on(bufnr, pos.line - 1)
  if entry then
    -- The marker's first segment starts GAP cells after the last character.
    local text = vim.api.nvim_buf_get_lines(bufnr, pos.line - 1, pos.line, false)[1] or ""
    local last = vim.fn.screenpos(pos.winid, pos.line, math.max(#text, 1))
    local offset = pos.screencol - (last.endcol + 1 + GAP)
    if last.row == pos.screenrow then
      for _, seg in ipairs(entry.segments) do
        if seg.locations and offset >= seg.start and offset < seg.start + seg.width then
          local client = gopls(bufnr)
          if client then
            vim.schedule(function() show(seg.locations, client.offset_encoding, seg.title) end)
          end
          break
        end
      end
    end
  end
  return "<LeftMouse>"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function M.attach(bufnr)
  detach(bufnr)
  state[bufnr] = { gen = 0, pending = {}, targets = {}, timer = vim.uv.new_timer(), stale = false }

  vim.keymap.set("n", "<LeftMouse>", on_click, {
    buffer = bufnr, expr = true, desc = "Go: open usages / implementations from the marker",
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = bufnr,
    callback = function() schedule_refresh(bufnr) end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      if state[bufnr] and state[bufnr].stale then M.refresh(bufnr) end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "LspDetach" }, {
    group = group,
    buffer = bufnr,
    callback = function(args)
      if args.event == "LspDetach" then
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if not client or client.name ~= "gopls" then return end
      end
      detach(bufnr)
    end,
  })

  M.refresh(bufnr)
end

-- Comment's colour in italic; links are underlined as well. A link cannot add
-- attributes, so the colour is copied again whenever the colorscheme changes.
local function set_highlights()
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  local base = { fg = comment.fg, ctermfg = comment.ctermfg, italic = true }
  vim.api.nvim_set_hl(0, "GoLens", base)
  vim.api.nvim_set_hl(0, "GoLensLink", vim.tbl_extend("force", base, { underline = true }))
end

function M.setup()
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

  -- A save anywhere can change usages or implementations of a declaration in
  -- another file: refresh what is on screen now, the rest when it is entered.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.go",
    callback = function()
      local visible = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        visible[vim.api.nvim_win_get_buf(win)] = true
      end
      for bufnr, st in pairs(state) do
        if visible[bufnr] then M.refresh(bufnr) else st.stale = true end
      end
    end,
  })
end

return M
