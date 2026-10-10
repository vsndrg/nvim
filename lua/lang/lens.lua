-- GoLand-style code vision, drawn at the end of the declaration line:
--   3 usages              references to a type / function / method / var;
--   ↓ 3 impl              what implements an interface, overrides a method;
--   ↑ Shape, fmt.Stringer what a concrete type / method implements (Go).
-- Every underlined word is clickable. `gi` jumps to the ↓ / ↑ targets of the
-- cursor line, `gu` to its usages: one target is opened directly, several go
-- to a Telescope picker.
--
-- Everything comes from the language server: textDocument/documentSymbol finds
-- the declarations, textDocument/references counts usages,
-- textDocument/implementation answers ↓ / ↑, and documentSymbol of each ↑
-- target file names the interfaces behind it. Which declarations get which
-- question is up to the language's spec:
--
--   {
--     client   = "gopls",
--     -- What to ask about `sym` (a child of `parent`, nil at the top level):
--     -- any of "usages", "down", "up".
--     queries  = function(sym, parent, bufnr) return { "usages" } end,
--     up_name  = function(name, uri, own_dir) return name end, -- ↑ label, nil drops it
--     fallback = "textDocument/definition", -- `gi` when implementation is empty
--     remember = true, -- keep relations an interface change broke, see below
--   }
--
-- With structural typing (Go) a method added to an interface breaks every
-- implementation of it until each type has the method too, and the server
-- answers nothing at all: the marker would lose exactly the targets that need
-- the new method. A spec with `remember` keeps each relation the server has
-- confirmed, with the interface's members at that moment. While the server
-- no longer confirms it, the relation stays as long as the interface has
-- changed since: added, renamed or re-typed members are what the type is
-- missing, shown in the warning colour and named in the picker. A relation
-- broken on the type's side, or whose declarations are gone, is forgotten.
--
--   require("lang.lens").attach(bufnr, spec)  -- on LspAttach
--   require("lang.lens").open(bufnr)          -- ↓ / ↑ targets for the cursor line
--   require("lang.lens").usages(bufnr)        -- usages for the cursor line

local M = {}

local ns = vim.api.nvim_create_namespace("lens")
local group = vim.api.nvim_create_augroup("Lens", { clear = true })

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

-- [bufnr] = {
--   spec    = table,              -- the language's spec, see above
--   gen     = number,             -- bumped by every refresh; older replies drop
--   pending = { request_id... },  -- in-flight requests of this gen
--   targets = { [extmark_id] = { kind, locations, usages, segments } },
--   timer   = uv_timer,
--   stale   = bool,               -- another file was saved while hidden
-- }
local state = {}

local function client_of(bufnr)
  local st = state[bufnr]
  return st and vim.lsp.get_clients({ bufnr = bufnr, name = st.spec.client })[1]
end

local function cancel_pending(st, client)
  for _, id in ipairs(st.pending) do
    pcall(client.cancel_request, client, id)
  end
  st.pending = {}
end

-- Every declaration of the document tree, with what the spec asks about it.
-- `name` is "Shape" for a top-level declaration, "Shape.Area" for a member;
-- `top` is the top-level one.
local function collect_queries(symbols, spec, bufnr)
  local queries = {}
  local function walk(list, parent)
    for _, sym in ipairs(list or {}) do
      if sym.selectionRange then
        for _, what in ipairs(spec.queries(sym, parent, bufnr)) do
          table.insert(queries, {
            pos = sym.selectionRange.start,
            what = what,
            name = parent and (parent.name .. "." .. sym.name) or sym.name,
            top = parent and parent.name or sym.name,
          })
        end
      end
      walk(sym.children, sym)
    end
  end
  walk(symbols, nil)
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

local function encloses(sym, pos)
  local range = sym.range or (sym.location and sym.location.range)
  return range ~= nil and before_or_at(range.start, pos) and before_or_at(pos, range["end"])
end

-- Declaration of `symbols` at `pos`, named as in collect_queries, and its
-- top-level declaration's name: the interface itself for a type-level
-- target, the interface owning the method for a method one.
local function symbol_at(symbols, pos)
  for _, sym in ipairs(symbols or {}) do
    if encloses(sym, pos) then
      for _, child in ipairs(sym.children or {}) do
        if encloses(child, pos) then return sym.name .. "." .. child.name, sym.name end
      end
      return sym.name, sym.name
    end
  end
  return nil
end

-- The declaration symbol_at() names `name`, or nil once it is gone.
local function find_symbol(symbols, name)
  for _, sym in ipairs(symbols or {}) do
    if sym.name == name then return sym end
    for _, child in ipairs(sym.children or {}) do
      if sym.name .. "." .. child.name == name then return child end
    end
  end
  return nil
end

-- { [member] = signature } of a declaration.
local function members_of(sym)
  local members = {}
  for _, child in ipairs(sym.children or {}) do members[child.name] = child.detail or "" end
  return members
end

-- Relations confirmed by the server, for specs with `remember`:
-- [key] = {
--   iface   = { uri, name },   -- "Shape" or "Shape.Area"
--   impl    = { uri, name },   -- "Circle" or "(*Circle).Area"
--   owner   = "Shape",         -- the interface `members` describe
--   members = { [name] = signature },  -- owner's members when last confirmed
--   dirs    = { down = true, up = true },  -- markers that may show it
-- }
-- A method relation only goes where the server showed it: ↓ of an interface
-- method lists a promoted method under the embedded type that declares it,
-- whose own ↑ never lists the interface.
local relations = {}

local function relation_key(iface, impl)
  return ("%s#%s|%s#%s"):format(iface.uri, iface.name, impl.uri, impl.name)
end

local function plural(n, word)
  if n == 0 then return "no " .. word .. "s" end
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- Segments of one line's marker, left to right. A segment with `locations`
-- is a link: underlined and clickable.
local function segments_of(entry)
  local segs = {}
  local function text(t) table.insert(segs, { text = t, hl = "Lens" }) end
  local function link(t, locations, title, hl)
    table.insert(segs, { text = t, hl = hl or "LensLink", locations = locations, title = title })
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
    local complete, incomplete = {}, {}
    for _, loc in ipairs(entry.down) do
      table.insert(loc.missing and incomplete or complete, loc)
    end
    gap()
    text("↓ ")
    if #complete > 0 then link(("%d impl"):format(#complete), complete, TITLES.down) end
    if #incomplete > 0 then
      if #complete > 0 then text(", ") end
      link(("%d incomplete"):format(#incomplete), incomplete, TITLES.down, "LensIncomplete")
    end
  end
  if #entry.up_groups > 0 then
    gap()
    text("↑ ")
    for i = 1, math.min(#entry.up_groups, MAX_NAMES) do
      if i > 1 then text(", ") end
      local grp = entry.up_groups[i]
      link(grp.name, grp.locations, TITLES.up, grp.incomplete and "LensIncomplete" or nil)
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
      local chunks, offset = { { string.rep(" ", GAP - 1), "Lens" } }, 0
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
  local client = client_of(bufnr)
  if not client or not vim.api.nvim_buf_is_loaded(bufnr) then return end

  cancel_pending(st, client)
  st.gen = st.gen + 1
  st.stale = false
  local gen = st.gen
  -- Positions from the server describe the text of the document version it
  -- was sent; once the buffer moved on, the debounced refresh scheduled by
  -- that edit takes over. Not changedtick: loading a file bumps it after
  -- LspAttach without changing the text, which would drop the first answer of
  -- every file opened while the server is already running.
  local version = vim.lsp.util.buf_versions[bufnr]
  local function current()
    return state[bufnr] == st and st.gen == gen
      and vim.api.nvim_buf_is_loaded(bufnr)
      and vim.lsp.util.buf_versions[bufnr] == version
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
  local own_uri = vim.uri_from_bufnr(bufnr)
  local lines = {}
  local function entry_at(line)
    lines[line] = lines[line] or { down = {}, up = {}, up_groups = {}, seen = {} }
    return lines[line]
  end
  local function add(query, loc)
    local entry = entry_at(query.pos.line)
    local key = location_key(loc)
    if not entry.seen[key] then
      entry.seen[key] = true
      table.insert(entry[query.what], loc)
    end
  end

  -- Each ↓ / ↑ query, as asked by `queries`, that the server answered: by
  -- "down|Shape" and the like.
  local function answered_queries(queries)
    local answered = {}
    for _, query in ipairs(queries) do
      if query.locations then answered[query.what .. "|" .. query.name] = query end
    end
    return answered
  end

  -- The query of this buffer a relation is the answer to in direction `what`.
  local function query_of(answered, rel, what)
    local own = what == "down" and rel.iface or rel.impl
    return own.uri == own_uri and answered[what .. "|" .. own.name] or nil
  end

  -- Records every relation the server has just confirmed, then adds those it
  -- no longer confirms but an interface change explains, see the top of the
  -- file.
  local function remember(queries, symbols_of)
    local confirmed = {}
    for _, query in ipairs(queries) do
      for _, loc in ipairs(query.locations or {}) do
        local name, top = symbol_at(symbols_of[loc_uri(loc)], loc_start(loc))
        if name then
          local here, there = { uri = own_uri, name = query.name }, { uri = loc_uri(loc), name = name }
          local iface, impl = here, there
          local owner = query.top
          if query.what == "up" then iface, impl, owner = there, here, top end
          local owner_sym = find_symbol(symbols_of[iface.uri], owner)
          if owner_sym then
            local key = relation_key(iface, impl)
            local rel = relations[key] or { dirs = {} }
            relations[key] = rel
            rel.iface, rel.impl, rel.owner, rel.members = iface, impl, owner, members_of(owner_sym)
            -- Type relations hold both ways; see `relations` for methods.
            if owner == iface.name then
              rel.dirs.down, rel.dirs.up = true, true
            else
              rel.dirs[query.what] = true
            end
            confirmed[key] = true
          end
        end
      end
    end

    local answered = answered_queries(queries)
    for key, rel in pairs(relations) do
      if not confirmed[key] then
        for what in pairs(rel.dirs) do
          local query = query_of(answered, rel, what)
          local other = what == "down" and rel.impl or rel.iface
          local other_symbols, iface_symbols = symbols_of[other.uri], symbols_of[rel.iface.uri]
          -- A file the server could not list says nothing either way.
          if query and other_symbols and iface_symbols then
            local target = find_symbol(other_symbols, other.name)
            local owner_sym = find_symbol(iface_symbols, rel.owner)
            local missing = {}
            if target and owner_sym then
              for _, child in ipairs(owner_sym.children or {}) do
                if rel.members[child.name] ~= (child.detail or "") then
                  table.insert(missing, child.name)
                end
              end
            end
            if #missing == 0 then
              relations[key] = nil
              break
            end
            add(query, { uri = other.uri, range = target.selectionRange, missing = missing })
          end
        end
      end
    end
  end

  -- Phase 2: name what every ↓ / ↑ location points at, one documentSymbol
  -- request per target file, plus the files of remembered relations.
  local function resolve_names(queries, own_symbols)
    local symbols_of = { [own_uri] = own_symbols }
    local by_uri = {}
    for _, entry in pairs(lines) do
      for _, loc in ipairs(entry.up) do by_uri[loc_uri(loc)] = true end
      if st.spec.remember then
        for _, loc in ipairs(entry.down) do by_uri[loc_uri(loc)] = true end
      end
    end
    if st.spec.remember then
      local answered = answered_queries(queries)
      for _, rel in pairs(relations) do
        for what in pairs(rel.dirs) do
          if query_of(answered, rel, what) then
            by_uri[rel.iface.uri], by_uri[rel.impl.uri] = true, true
          end
        end
      end
    end
    by_uri[own_uri] = nil
    local remaining = vim.tbl_count(by_uri)

    local function finish()
      if st.spec.remember then remember(queries, symbols_of) end
      for _, entry in pairs(lines) do
        local kept, groups, by_name = {}, {}, {}
        for _, loc in ipairs(entry.up) do
          local _, name = symbol_at(symbols_of[loc_uri(loc)], loc_start(loc))
          if name and st.spec.up_name then name = st.spec.up_name(name, loc_uri(loc), own_dir) end
          if name then
            table.insert(kept, loc)
            if not by_name[name] then
              by_name[name] = { name = name, locations = {}, incomplete = true }
              table.insert(groups, by_name[name])
            end
            table.insert(by_name[name].locations, loc)
            by_name[name].incomplete = by_name[name].incomplete and loc.missing ~= nil
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

    local queries = collect_queries(symbols, st.spec, bufnr)
    local remaining = #queries
    if remaining == 0 then return render(bufnr, lines) end

    local function done()
      remaining = remaining - 1
      if remaining == 0 then resolve_names(queries, symbols) end
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
          -- Only an answer may forget a remembered relation, see remember().
          if not impl_err then
            query.locations = as_list(result)
            for _, loc in ipairs(query.locations) do add(query, loc) end
          end
          done()
        end)
      end
      if not sent then remaining = remaining - 1 end
    end
    if remaining == 0 then resolve_names(queries, symbols) end
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
  local client = client_of(bufnr)
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

  local function parsed(filename)
    if files[filename] == nil then
      local bufnr = vim.fn.bufnr(filename)
      local loaded = bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)
      local lines = loaded and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        or vim.F.npcall(vim.fn.readfile, filename) or {}
      local ft = loaded and vim.bo[bufnr].filetype or vim.filetype.match({ filename = filename })
      local lang = ft and vim.treesitter.language.get_lang(ft)
      local query = lang and vim.F.npcall(vim.treesitter.query.get, lang, "highlights")
      local text = table.concat(lines, "\n")
      local parser = query and vim.F.npcall(vim.treesitter.get_string_parser, text, lang)
      local tree = parser and parser:parse()[1]
      files[filename] = tree
        and { root = tree:root(), text = text, lines = lines, lang = lang, query = query }
        or false
    end
    return files[filename]
  end

  return function(filename, row)
    local file = parsed(filename)
    if not file then return {} end
    local query = file.query
    local len = #(file.lines[row + 1] or "")
    local ranges = {}
    for id, node in query:iter_captures(file.root, file.text, row, row + 1) do
      local name = query.captures[id]
      if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" then
        local sr, sc, er, ec = node:range()
        if sr < row then sc = 0 end
        if er > row then ec = len end
        if ec > sc then table.insert(ranges, { sc, ec, "@" .. name .. "." .. file.lang }) end
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
    local code_len = #code
    -- What a type of an incomplete relation lacks, after its code.
    local missing = item.user_data and item.user_data.missing
    if missing then code = code .. "  missing " .. table.concat(missing, ", ") end
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
              local from, to = math.max(r[1] - indent, 0), math.min(r[2] - indent, code_len)
              if to > from then table.insert(hls, { { from, to }, r[3] }) end
            end
            if missing then table.insert(hls, { { code_len + 2, #code }, "DiagnosticWarn" }) end
            return hls
          end },
        })
      end,
    }
  end
end

-- Opens one location, or a picker of several. `done`, if given, runs once
-- the cursor has landed on the target.
local function show(locations, encoding, title, done)
  done = done or function() end
  if #locations == 1 then
    vim.lsp.util.show_document(locations[1], encoding, { focus = true, reuse_win = true })
    vim.cmd("normal! zz")
    done()
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
      attach_mappings = function(prompt_bufnr, map)
        map({ "i", "n" }, "<CR>", function()
          require("telescope.actions").select_default(prompt_bufnr)
          done()
        end)
        return true
      end,
    }):find()
  end)
  if not ok then
    for _, item in ipairs(items) do
      local missing = item.user_data and item.user_data.missing
      if missing then item.text = item.text .. "  missing " .. table.concat(missing, ", ") end
    end
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

-- Whether `loc` is the symbol under the cursor (`params`): a jump there goes
-- nowhere. Files are compared by inode, since the server and the buffer may
-- spell a path on a case-insensitive disk differently.
local function is_here(loc, params)
  local range = loc.targetSelectionRange or loc.range
  if not (before_or_at(range.start, params.position) and before_or_at(params.position, range["end"])) then
    return false
  end
  local a = vim.uv.fs_stat(vim.uri_to_fname(loc_uri(loc)))
  local b = vim.uv.fs_stat(vim.uri_to_fname(params.textDocument.uri))
  return a ~= nil and b ~= nil and a.dev == b.dev and a.ino == b.ino
end

-- Every declaration and definition of the symbol: its references counted
-- with declarations minus those without. Finds what textDocument/declaration
-- misses, like the `extern` prototype in another .c file of a function whose
-- body the cursor is on.
local function declarations_by_references(client, params, bufnr, callback)
  local function refs(include, cb)
    local p = vim.tbl_extend("force", params, { context = { includeDeclaration = include } })
    client:request("textDocument/references", p, function(err, result) cb(not err and result or nil) end, bufnr)
  end
  refs(true, function(all)
    if not all then return callback({}) end
    refs(false, function(uses)
      if not uses then return callback({}) end
      local used = {}
      for _, loc in ipairs(uses) do used[location_key(loc)] = true end
      callback(vim.tbl_filter(function(loc) return not used[location_key(loc)] end, all))
    end)
  end)
end

-- Shared by `gi` and `gu`: the cursor line's marker answers first, so both
-- keys work from anywhere on a declaration line; a line without an answer
-- in its marker asks the server about the symbol under the cursor, so a call
-- site like `s.Area()` works too. `methods` (LSP methods, or functions
-- `(client, params, bufnr, callback(locations))`) are tried in order until
-- one finds something other than the cursor's own symbol.
local function open_at_cursor(bufnr, from_marker, methods, context, title, empty_msg, done)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local client = client_of(bufnr)
  if not client then
    vim.notify("No language server with code vision is attached", vim.log.levels.WARN)
    return
  end

  local entry = from_marker and marker_on(bufnr, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if entry then
    local locations, marker_title = from_marker(entry)
    if locations and #locations > 0 then
      show(locations, client.offset_encoding, marker_title, done)
      return
    end
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = context
  local function request(method, callback)
    if type(method) == "function" then return method(client, params, bufnr, callback) end
    client:request(method, params, function(err, result)
      callback(err and {} or as_list(result))
    end, bufnr)
  end
  local function try(i)
    if not methods[i] then
      vim.notify(empty_msg, vim.log.levels.INFO)
      return
    end
    request(methods[i], function(locations)
      locations = vim.tbl_filter(function(loc) return not is_here(loc, params) end, locations)
      if #locations == 0 then return try(i + 1) end
      show(locations, client.offset_encoding, title, done)
    end)
  end
  try(1)
end

-- ↓ / ↑ targets (`gi`), or the spec's fallback when there are none.
function M.open(bufnr, done)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local st = state[bufnr]
  open_at_cursor(bufnr, function(entry) return entry.locations, TITLES[entry.kind] end,
    { "textDocument/implementation", st and st.spec.fallback },
    nil, TITLES.down, "No implementations found", done)
end

-- Usages without the declaration itself, as counted in the marker (`gu`).
function M.usages(bufnr, done)
  open_at_cursor(bufnr, function(entry) return entry.usages, TITLES.usages end,
    { "textDocument/references" }, { includeDeclaration = false }, TITLES.usages, "No usages found", done)
end

-- Declaration of the symbol under the cursor: a C prototype in its header,
-- or wherever else it is declared when the server ranks none above the body
-- the cursor is on.
function M.declaration(bufnr, done)
  open_at_cursor(bufnr, nil, { "textDocument/declaration", declarations_by_references }, nil,
    "Declarations", "No declaration found", done)
end

-- The last jump made through toggle(): its key, where it started and where
-- it landed.
local last_jump

-- Mapping for `key` that runs `jump(done)`; pressed again where that jump
-- landed (the cursor still on the line), it comes back to where it started.
function M.toggle(key, jump)
  return function()
    local here = { buf = vim.api.nvim_get_current_buf(), pos = vim.api.nvim_win_get_cursor(0) }
    local back = last_jump
    if back and back.key == key and back.to.buf == here.buf and back.to.pos[1] == here.pos[1]
      and vim.api.nvim_buf_is_valid(back.from.buf) then
      last_jump = nil
      vim.cmd("normal! m'")
      vim.cmd.buffer(back.from.buf)
      pcall(vim.api.nvim_win_set_cursor, 0, back.from.pos)
      vim.cmd("normal! zz")
      return
    end
    jump(function()
      last_jump = {
        key = key,
        from = here,
        to = { buf = vim.api.nvim_get_current_buf(), pos = vim.api.nvim_win_get_cursor(0) },
      }
    end)
  end
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
          local client = client_of(bufnr)
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

-- Comment's colour in italic; links are underlined as well. A link cannot add
-- attributes, so the colour is copied again whenever the colorscheme changes.
local function set_highlights()
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  local base = { fg = comment.fg, ctermfg = comment.ctermfg, italic = true }
  vim.api.nvim_set_hl(0, "Lens", base)
  vim.api.nvim_set_hl(0, "LensLink", vim.tbl_extend("force", base, { underline = true }))
  -- A relation the type no longer fulfils: the warning colour.
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  vim.api.nvim_set_hl(0, "LensIncomplete", { fg = warn.fg, ctermfg = warn.ctermfg, italic = true, underline = true })
end

local did_setup = false

local function setup()
  did_setup = true
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

  -- A save can change usages or implementations of a declaration in another
  -- file of the same language: refresh what is on screen now, the rest when
  -- it is entered.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      local written = state[args.buf]
      if not written then return end
      local visible = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        visible[vim.api.nvim_win_get_buf(win)] = true
      end
      for bufnr, st in pairs(state) do
        if st.spec == written.spec then
          if visible[bufnr] then M.refresh(bufnr) else st.stale = true end
        end
      end
    end,
  })
end

function M.attach(bufnr, spec)
  if not did_setup then setup() end
  detach(bufnr)
  state[bufnr] = {
    spec = spec, gen = 0, pending = {}, targets = {}, timer = vim.uv.new_timer(), stale = false,
  }

  vim.keymap.set("n", "<LeftMouse>", on_click, {
    buffer = bufnr, expr = true, desc = "Open usages / implementations from the marker",
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
        if not client or client.name ~= spec.client then return end
      end
      detach(bufnr)
    end,
  })

  M.refresh(bufnr)
end

return M
