-- Graphical markdown preview inside Neovide.
--
-- A preview is a scratch "view" buffer whose window is covered by a native
-- WKWebView (patched Neovide, `neovide.webview`). Modes per source buffer:
--   code     preview hidden (webview kept alive for fast toggling)
--   split    view window to the right of the source window
--   preview  view buffer replaces the source in its window
local build = require("mdpreview.build")
local theme = require("mdpreview.theme")

local M = {}

local uv = vim.uv
local api = vim.api

local sessions = {} ---@type table<integer, table> source bufnr -> session
local by_view = {} ---@type table<integer, table> view bufnr -> session
local next_id = 1
local theme_name = theme.load_choice()

-- ------------------------------------------------------------ availability

local warned = false

local function available()
  local reason
  if not vim.g.neovide then
    reason = "graphical preview needs Neovide"
  elseif not (type(_G.neovide) == "table" and _G.neovide.webview) then
    reason = "this Neovide build has no webview support (use ~/.local/bin/neovide-patched)"
  else
    local ui = api.nvim_list_uis()[1]
    if ui and ui.ext_multigrid == false then
      reason = "Neovide runs with --no-multigrid; the preview needs multigrid"
    end
  end
  if reason and not warned then
    warned = true
    vim.notify("mdpreview: " .. reason, vim.log.levels.WARN)
  end
  return reason == nil
end

-- ------------------------------------------------------------------ helpers

local function post(s, msg)
  if s.ready then
    neovide.webview.post(s.id, vim.json.encode(msg))
  end
end

local function buf_text(buf)
  return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function doc_dir(buf)
  local name = api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
end

-- Windows showing `buf`, preferring the current tabpage.
local function windows_with(buf)
  local tab = api.nvim_get_current_tabpage()
  local wins = vim.fn.win_findbuf(buf)
  table.sort(wins, function(a, b)
    local ta, tb = api.nvim_win_get_tabpage(a) == tab, api.nvim_win_get_tabpage(b) == tab
    if ta ~= tb then
      return ta
    end
    return a < b
  end)
  return wins
end

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end

-- Source window to follow/drive: the current window if it shows the source.
local function source_window(s)
  local cur = api.nvim_get_current_win()
  if api.nvim_win_get_buf(cur) == s.src then
    return cur
  end
  return windows_with(s.src)[1]
end

local function topline(win)
  return vim.fn.getwininfo(win)[1].topline
end

local function send_update(s)
  if not s.ready then
    return
  end
  post(s, { type = "update", text = buf_text(s.src), docDir = doc_dir(s.src) })
end

local function send_follow(s)
  local win = source_window(s)
  if not win or s.mode ~= "split" then
    return
  end
  if s.suppress_follow_until and uv.now() < s.suppress_follow_until then
    return
  end
  post(s, { type = "follow", line = topline(win) - 1 })
end

local function send_cursor(s)
  local win = source_window(s)
  if win then
    post(s, { type = "cursor", line = api.nvim_win_get_cursor(win)[1] - 1 })
  end
end

local function send_theme(s)
  post(s, theme.message(theme_name))
end

-- Point the webview at whichever window currently shows the view buffer.
local function rebind(s)
  if not s.view or not api.nvim_buf_is_valid(s.view) then
    return
  end
  local win = windows_with(s.view)[1] or 0
  if win ~= s.bound_win then
    s.bound_win = win
    neovide.webview.set_window(s.id, win)
  end
end

-- ----------------------------------------------------------- view buffer

local VIEW_WIN_OPTS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  cursorline = false,
  cursorcolumn = false,
  colorcolumn = "",
  list = false,
  spell = false,
  wrap = false,
  fillchars = "eob: ",
}

local function setup_view_window(win)
  for k, v in pairs(VIEW_WIN_OPTS) do
    vim.wo[win][k] = v
  end
end

local function close_session(s) end -- forward declaration, defined below
local function set_mode(s, mode) end

-- Keyboard focus: while the preview window is current (normal mode, nothing
-- pending) the webview owns the keyboard, so j/k scroll from keydown to keyup
-- without key-repeat delay. Keys it does not handle are replayed here.
local function view_is_current(s)
  return s.view and api.nvim_get_current_buf() == s.view
end

-- Keys the page handles itself (see handlePreviewKey in web/src/main.js).
-- Neovide routes every other key straight back to nvim, in order.
local PAGE_KEYS = {
  "j", "k", "d", "u", "f", "b", "g", "G", "n", "N",
  "<Esc>", "<Up>", "<Down>", "<PageUp>", "<PageDown>", "<Home>", "<End>",
}

local function set_webview_focus(s, focus)
  if s.focused == focus then
    return
  end
  s.focused = focus
  post(s, { type = "ownKeys", enabled = focus })
  neovide.webview.focus(s.id, focus, focus and PAGE_KEYS or nil)
end

local function refocus(s)
  if s.ready and view_is_current(s) and api.nvim_get_mode().mode == "n" then
    set_webview_focus(s, true)
  end
end

-- Fallback for keys that reached nvim (the webview did not have focus yet).
local function scroll(s, action, n)
  post(s, { type = "scroll", action = action, n = n })
  refocus(s)
end

local function find_prompt(s, backwards)
  vim.ui.input({ prompt = backwards and "?" or "/" }, function(query)
    if query and query ~= "" then
      s.last_query = query
      post(s, { type = "find", query = query, backwards = backwards })
    end
  end)
end

local function view_keymaps(s)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = s.view, nowait = true, silent = true, desc = desc })
  end
  map("j", function() scroll(s, "line", vim.v.count1) end, "Preview: scroll down")
  map("k", function() scroll(s, "line", -vim.v.count1) end, "Preview: scroll up")
  map("<Down>", function() scroll(s, "line", vim.v.count1) end, "Preview: scroll down")
  map("<Up>", function() scroll(s, "line", -vim.v.count1) end, "Preview: scroll up")
  map("<C-e>", function() scroll(s, "line", vim.v.count1) end, "Preview: scroll down")
  map("<C-y>", function() scroll(s, "line", -vim.v.count1) end, "Preview: scroll up")
  map("d", function() scroll(s, "halfpage", vim.v.count1) end, "Preview: half page down")
  map("u", function() scroll(s, "halfpage", -vim.v.count1) end, "Preview: half page up")
  map("f", function() scroll(s, "page", vim.v.count1) end, "Preview: page down")
  map("b", function() scroll(s, "page", -vim.v.count1) end, "Preview: page up")
  map("<PageDown>", function() scroll(s, "page", 1) end, "Preview: page down")
  map("<PageUp>", function() scroll(s, "page", -1) end, "Preview: page up")
  map("gg", function() scroll(s, "top") end, "Preview: top")
  map("G", function() scroll(s, "bottom") end, "Preview: bottom")
  map("/", function() find_prompt(s, false) end, "Preview: search")
  map("?", function() find_prompt(s, true) end, "Preview: search backwards")
  map("n", function() post(s, { type = "findNext", backwards = false }) end, "Preview: next match")
  map("N", function() post(s, { type = "findNext", backwards = true }) end, "Preview: previous match")
  map("<Esc>", function() post(s, { type = "clearFind" }) end, "Preview: clear search")
  map("q", function() close_session(s) end, "Preview: close")
  map("<CR>", function()
    if s.mode == "preview" then
      set_mode(s, "code")
    else
      local win = source_window(s)
      if win and s.preview_line then
        local line = math.floor(s.preview_line) + 1
        api.nvim_set_current_win(win)
        api.nvim_win_set_cursor(win, { math.min(line, api.nvim_buf_line_count(s.src)), 0 })
      end
    end
  end, "Preview: go to source")
end

local function view_name(src)
  local name = api.nvim_buf_get_name(src)
  return "mdpreview://" .. (name ~= "" and vim.fn.fnamemodify(name, ":~:.") or tostring(src))
end

local function create_view(s)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "mdpreview"
  pcall(api.nvim_buf_set_name, buf, view_name(s.src))
  s.view = buf
  by_view[buf] = s
  view_keymaps(s)
  M.buffer_keymaps(buf)
end

-- ------------------------------------------------------------ JS messages

-- GitHub-style heading slug, to resolve `file.md#anchor` links.
local function slug(text)
  text = text:lower():gsub("[%c%p]", function(c)
    return (c == "-" or c == "_") and c or ""
  end)
  return (text:gsub("%s", "-"))
end

local function jump_to_anchor(buf, win, anchor)
  if not anchor or anchor == "" then
    return
  end
  anchor = anchor:lower()
  local in_fence = false
  for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      in_fence = not in_fence
    elseif not in_fence then
      local heading = line:match("^#+%s+(.-)%s*#*%s*$")
      if heading and slug(heading) == anchor then
        api.nvim_win_set_cursor(win, { i, 0 })
        vim.cmd("normal! zt")
        return
      end
    end
  end
end

local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function open_link(s, href)
  if href:match("^%a[%w+.-]*:") and not href:match("^file:") then
    vim.ui.open(href)
    return
  end
  local path, anchor = href:gsub("^file://", ""):match("^([^#]*)#?(.*)$")
  path = url_decode(path)
  if path == "" then
    return
  end
  if not path:match("^/") then
    path = doc_dir(s.src) .. "/" .. path
  end
  path = vim.fn.fnamemodify(path, ":p")
  local stat = uv.fs_stat(path)
  local is_md = path:match("%.md$") or path:match("%.markdown$")
  if not stat or stat.type ~= "file" or not is_md then
    vim.ui.open(path)
    return
  end
  local was_preview = s.mode == "preview"
  if was_preview then
    set_mode(s, "code")
  end
  local win = source_window(s) or api.nvim_get_current_win()
  api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(path))
  jump_to_anchor(api.nvim_get_current_buf(), win, url_decode(anchor))
  if was_preview then
    M.open(api.nvim_get_current_buf(), "preview")
  end
end

local function toggle_task(s, line)
  local lnum = line + 1
  local text = api.nvim_buf_get_lines(s.src, line, lnum, false)[1]
  if not text then
    return
  end
  local new, n = text:gsub("^(%s*[-*+]%s+)%[ %]", "%1[x]", 1)
  if n == 0 then
    new, n = text:gsub("^(%s*%d+[.)]%s+)%[ %]", "%1[x]", 1)
  end
  if n == 0 then
    new, n = text:gsub("^(%s*[-*+]%s+)%[[xX]%]", "%1[ ]", 1)
  end
  if n == 0 then
    new, n = text:gsub("^(%s*%d+[.)]%s+)%[[xX]%]", "%1[ ]", 1)
  end
  if n > 0 then
    api.nvim_buf_set_lines(s.src, line, lnum, false, { new })
  end
end

local function goto_source_line(s, line)
  local lnum = math.max(1, math.min(line + 1, api.nvim_buf_line_count(s.src)))
  if s.mode == "preview" then
    s.code_cursor = { lnum, 0 }
    return
  end
  local win = source_window(s)
  if win then
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { lnum, 0 })
  end
end

local handlers = {}

function handlers.ready(s)
  s.ready = true
  send_theme(s)
  post(s, { type = "activeLine", enabled = s.mode == "split" })
  post(s, { type = "update", text = buf_text(s.src), docDir = doc_dir(s.src) })
  local win = source_window(s)
  if win then
    post(s, { type = "follow", line = topline(win) - 1 })
    send_cursor(s)
  elseif s.preview_line then
    post(s, { type = "scroll", action = "toline", n = s.preview_line })
  end
end

function handlers.click(s, msg)
  if s.mode == "preview" then
    s.code_cursor = { math.max(1, math.min(msg.line + 1, api.nvim_buf_line_count(s.src))), 0 }
    local win = windows_with(s.view)[1]
    if win then
      api.nvim_set_current_win(win)
    end
  else
    goto_source_line(s, msg.line)
  end
end

function handlers.dblclick(s, msg)
  if s.mode == "preview" then
    s.code_cursor = { math.max(1, math.min(msg.line + 1, api.nvim_buf_line_count(s.src))), 0 }
    set_mode(s, "code")
  else
    goto_source_line(s, msg.line)
  end
end

function handlers.scrolled(s, msg)
  s.preview_line = msg.line
  if msg.echo or s.mode ~= "split" then
    return
  end
  local win = source_window(s)
  if not win then
    return
  end
  local line = math.max(1, math.min(math.floor(msg.line) + 1, api.nvim_buf_line_count(s.src)))
  if topline(win) ~= line then
    s.suppress_follow_until = uv.now() + 150
    api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = line })
    end)
  end
end

function handlers.link(s, msg)
  open_link(s, msg.href)
end

function handlers.copy(_, msg)
  vim.fn.setreg("+", msg.text)
  vim.notify(("mdpreview: copied %d characters"):format(vim.fn.strchars(msg.text)))
end

function handlers.blur(s)
  -- Neovide already returned the keyboard to nvim (and replayed msg.key in order).
  s.focused = false
end

function handlers.benchResult(_, msg)
  vim.g.mdpreview_bench = msg
  vim.notify(("mdpreview: %d fps (median %.1f ms, p95 %.1f ms, max %.1f ms, %d frames), step %g px, %d/%d uneven"):format(
    msg.fps, msg.median, msg.p95, msg.max, msg.frames, msg.step or 0, msg.uneven or 0, msg.steady or 0))
end

function handlers.toggleTask(s, msg)
  toggle_task(s, msg.line)
end

function handlers.findResult(s, msg)
  if msg.total == 0 then
    vim.notify("mdpreview: pattern not found: " .. (s.last_query or ""), vim.log.levels.WARN)
  else
    api.nvim_echo({ { ("[%d/%d] %s"):format(msg.index, msg.total, s.last_query or "") } }, false, {})
  end
end

local function on_message(s, raw)
  local ok, msg = pcall(vim.json.decode, raw)
  if not ok or type(msg) ~= "table" then
    return
  end
  local handler = handlers[msg.type]
  if handler then
    handler(s, msg)
  end
end

-- -------------------------------------------------------------- sessions

local function attach_autocmds(s)
  local group = api.nvim_create_augroup("mdpreview_" .. s.id, { clear = true })
  s.group = group
  local timer = uv.new_timer()
  s.timer = timer

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = s.src,
    callback = function()
      timer:stop()
      timer:start(30, 0, vim.schedule_wrap(function()
        if sessions[s.src] == s then
          send_update(s)
        end
      end))
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = s.src,
    callback = function()
      send_cursor(s)
    end,
  })
  api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      if s.mode == "split" and api.nvim_get_current_buf() == s.src then
        send_follow(s)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = s.src,
    callback = function()
      vim.schedule(function()
        close_session(s)
      end)
    end,
  })
  api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave", "WinClosed", "TabEnter", "WinNew" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        if sessions[s.src] ~= s then
          return
        end
        rebind(s)
        -- The user closed the preview window (`:q`, `<C-w>c`).
        if s.mode ~= "code" and not s.switching and #windows_with(s.view) == 0 then
          if s.mode == "split" or #windows_with(s.src) > 0 then
            s.mode = "code"
          else
            close_session(s)
          end
        end
      end)
    end,
  })
  -- Like VSCode's side preview: follow the markdown buffer shown in the source window.
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      if s.mode ~= "split" or ev.buf == s.src or vim.bo[ev.buf].filetype ~= "markdown" then
        return
      end
      if api.nvim_get_current_win() ~= s.src_win or sessions[ev.buf] then
        return
      end
      vim.schedule(function()
        if sessions[s.src] == s and api.nvim_buf_is_valid(ev.buf) and not sessions[ev.buf] then
          M.retarget(s, ev.buf)
        end
      end)
    end,
  })

  api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = function()
      if not s.focused then
        refocus(s)
      end
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      if view_is_current(s) then
        set_webview_focus(s, false)
      end
    end,
  })

  local function resend_theme()
    vim.schedule(function()
      send_theme(s)
    end)
  end
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = resend_theme })
  api.nvim_create_autocmd("OptionSet", { group = group, pattern = "background", callback = resend_theme })
end

close_session = function(s)
  if sessions[s.src] ~= s then
    return
  end
  sessions[s.src] = nil
  if s.view then
    by_view[s.view] = nil
  end
  if s.timer then
    s.timer:stop()
    s.timer:close()
  end
  pcall(api.nvim_del_augroup_by_id, s.group)
  neovide.webview.close(s.id)
  if s.view and api.nvim_buf_is_valid(s.view) then
    -- In preview mode the view occupies the source's window: put the source back.
    for _, win in ipairs(vim.fn.win_findbuf(s.view)) do
      if api.nvim_buf_is_valid(s.src) and s.mode == "preview" then
        api.nvim_win_set_buf(win, s.src)
      elseif #api.nvim_list_wins() > 1 then
        pcall(api.nvim_win_close, win, true)
      end
    end
    pcall(api.nvim_buf_delete, s.view, { force = true })
  end
end

-- Point an existing session (and its webview) at another source buffer.
function M.retarget(s, src)
  sessions[s.src] = nil
  s.src = src
  sessions[src] = s
  if s.timer then
    s.timer:stop()
    s.timer:close()
  end
  attach_autocmds(s)
  pcall(api.nvim_buf_set_name, s.view, view_name(src))
  post(s, { type = "update", text = buf_text(src), docDir = doc_dir(src) })
  send_follow(s)
  send_cursor(s)
end

local function new_session(src)
  local s = { id = next_id, src = src, mode = "code", ready = false, bound_win = nil }
  next_id = next_id + 1
  sessions[src] = s
  create_view(s)
  attach_autocmds(s)
  neovide.webview.on_message[s.id] = function(raw)
    on_message(s, raw)
  end
  neovide.webview.open(s.id, 0, build.index)
  s.bound_win = 0
  return s
end

set_mode = function(s, mode)
  if s.mode == mode then
    return
  end
  s.switching = true
  local prev = s.mode

  -- Leave the previous layout.
  if prev == "split" then
    for _, win in ipairs(windows_with(s.view)) do
      if #api.nvim_list_wins() > 1 then
        api.nvim_win_close(win, true)
      end
    end
  elseif prev == "preview" then
    for _, win in ipairs(windows_with(s.view)) do
      api.nvim_win_set_buf(win, s.src)
      local cursor = s.code_cursor
      if not cursor and s.preview_line then
        cursor = { math.floor(s.preview_line) + 1, 0 }
      end
      if cursor then
        cursor[1] = math.max(1, math.min(cursor[1], api.nvim_buf_line_count(s.src)))
        api.nvim_win_set_cursor(win, cursor)
        api.nvim_win_call(win, function()
          vim.cmd("normal! zt")
        end)
      end
      s.code_cursor = nil
    end
  end

  -- Enter the new one.
  local src_win = source_window(s)
  if mode == "split" then
    src_win = src_win or api.nvim_get_current_win()
    api.nvim_win_call(src_win, function()
      vim.cmd("rightbelow vsplit")
      local win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, s.view)
      setup_view_window(win)
      vim.wo[win].winfixbuf = true
    end)
    s.src_win = src_win
    api.nvim_set_current_win(src_win)
  elseif mode == "preview" then
    local win = src_win or api.nvim_get_current_win()
    if src_win then
      s.preview_line = topline(src_win) - 1
    end
    api.nvim_win_set_buf(win, s.view)
    setup_view_window(win)
    vim.wo[win].winfixbuf = false
    api.nvim_set_current_win(win)
  end

  s.mode = mode
  s.switching = false
  rebind(s)
  post(s, { type = "activeLine", enabled = mode == "split" })
  if mode == "split" then
    send_follow(s)
    send_cursor(s)
  elseif mode == "preview" and s.preview_line then
    post(s, { type = "scroll", action = "toline", n = s.preview_line })
  end
end

-- ------------------------------------------------------------- public API

local function current_session()
  local buf = api.nvim_get_current_buf()
  return by_view[buf] or sessions[buf], buf
end

---@param src integer source buffer
---@param mode "split"|"preview"|"code"
function M.open(src, mode)
  if not available() then
    return
  end
  build.ensure(function(ok)
    if not ok or not api.nvim_buf_is_valid(src) then
      return
    end
    local s = sessions[src] or new_session(src)
    set_mode(s, mode)
  end)
end

function M.toggle_preview()
  local s, buf = current_session()
  if s then
    set_mode(s, s.mode == "preview" and "code" or "preview")
  elseif vim.bo[buf].filetype == "markdown" then
    M.open(buf, "preview")
  end
end

function M.toggle_split()
  local s, buf = current_session()
  if s then
    set_mode(s, s.mode == "split" and "code" or "split")
  elseif vim.bo[buf].filetype == "markdown" then
    M.open(buf, "split")
  end
end

function M.close()
  local s = current_session()
  if s then
    close_session(s)
  end
end

-- Closes every preview (e.g. before a session is saved: view buffers are scratch).
function M.close_all()
  for _, s in pairs(vim.tbl_values(sessions)) do
    close_session(s)
  end
end

-- Session state for debugging (`:lua =require('mdpreview').status()`).
function M.status()
  local out = {}
  for src, s in pairs(sessions) do
    table.insert(out, {
      id = s.id,
      src = api.nvim_buf_get_name(src),
      mode = s.mode,
      ready = s.ready,
      focused = s.focused,
      preview_line = s.preview_line,
    })
  end
  return out
end

function M.set_theme(name)
  if name == "next" then
    name = theme.next(theme_name)
  end
  if not vim.tbl_contains(theme.names, name) then
    vim.notify("mdpreview: unknown theme " .. tostring(name), vim.log.levels.ERROR)
    return
  end
  theme_name = name
  theme.save_choice(name)
  for _, s in pairs(sessions) do
    send_theme(s)
  end
  vim.notify("mdpreview: theme " .. name)
end

function M.buffer_keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, desc = desc })
  end
  map("<leader>mp", M.toggle_preview, "Markdown preview (full window) toggle")
  map("<leader>ms", M.toggle_split, "Markdown preview split toggle")
  map("<leader>mt", function() M.set_theme("next") end, "Markdown preview next theme")
end

function M.setup()
  api.nvim_create_user_command("MdPreview", function(opts)
    local args = opts.fargs
    local sub = args[1] or "toggle"
    if sub == "toggle" or sub == "preview" then
      M.toggle_preview()
    elseif sub == "split" then
      M.toggle_split()
    elseif sub == "code" then
      local s = current_session()
      if s then
        set_mode(s, "code")
      end
    elseif sub == "close" then
      M.close()
    elseif sub == "bench" then
      local s = current_session()
      if s then
        post(s, { type = "bench" })
      end
    elseif sub == "theme" then
      M.set_theme(args[2] or "next")
    else
      vim.notify("mdpreview: unknown subcommand " .. sub, vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    complete = function(_, line)
      if line:match("theme%s+%S*$") then
        return vim.list_extend({ "next" }, vim.deepcopy(theme.names))
      end
      return { "toggle", "split", "code", "close", "theme" }
    end,
    bar = true,
    desc = "Markdown preview",
  })
  api.nvim_create_user_command("MdPreviewBuild", function()
    build.build(true)
  end, { desc = "Rebuild the markdown preview renderer" })

  local group = api.nvim_create_augroup("mdpreview", { clear = true })
  api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      M.buffer_keymaps(ev.buf)
    end,
  })
  -- Buffers already loaded before the plugin (lazy-loaded on ft=markdown).
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "markdown" then
      M.buffer_keymaps(buf)
    end
  end
end

return M
