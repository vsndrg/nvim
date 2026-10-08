-- Jump keys that peek when held. A tap jumps as usual. Held longer than
-- PEEK_MS, the key's release comes back as if the jump never happened: same
-- buffer and view, the alternate file and jumplist as before, Insert mode where
-- it was. Key releases come only from Neovide (neovide.on_key_release);
-- elsewhere the keys just jump.
local M = {}

local PEEK_MS = 200

local watches_release = vim.g.neovide and _G.neovide and neovide.on_key_release ~= nil

-- Buffer whose file the current window shows: a preview view stands for its
-- markdown source (mdpreview is loaded lazily; without it there are no views).
function M.current_source()
  local buf = vim.api.nvim_get_current_buf()
  local mdpreview = package.loaded["mdpreview"]
  return mdpreview and mdpreview.source_of(buf) or buf
end

-- Keys whose releases are reported.
local watched = {}

-- Per held key, the jump it made, until its release: where it started (window,
-- buffer and cursor, source buffer, view, alternate file, whether Insert mode
-- was left for it) and the source buffer it arrived at.
local holds = {}

-- A tap: add the jumplist entry the jump left out, as a plain jump would have
-- (the start position, appended by the ' mark). The buffer switches around it
-- are invisible (no redraw inside one callback) and skip autocommands, so
-- mdpreview does not see them.
local function record_jump(h)
  local here, view = vim.api.nvim_get_current_buf(), vim.fn.winsaveview()
  vim.cmd("noautocmd keepalt keepjumps buffer " .. h.buf)
  vim.api.nvim_win_set_cursor(0, h.cursor)
  vim.cmd("mark '")
  vim.cmd("noautocmd keepalt keepjumps buffer " .. here)
  vim.fn.winrestview(view)
end

-- A peek: back as if it never happened.
local function unpeek(h)
  vim.cmd("keepalt keepjumps buffer " .. h.src)
  if h.view then vim.fn.winrestview(h.view) end
  local alt = h.alt ~= -1 and vim.api.nvim_buf_is_valid(h.alt) and vim.api.nvim_buf_get_name(h.alt) or ""
  if alt ~= "" then vim.cmd("balt " .. vim.fn.fnameescape(alt)) end
  if h.left_insert then
    local pos = vim.api.nvim_buf_get_mark(0, "^")
    vim.api.nvim_win_set_cursor(0, pos)
    if pos[2] >= #vim.api.nvim_get_current_line() then
      vim.cmd("startinsert!")
    else
      vim.cmd("startinsert")
    end
  end
end

--- Make `key` (as Neovide sends it, e.g. "<C-b>") peek when held.
---@param key string
function M.watch(key)
  if not watches_release then return end
  watched[key] = true
  neovide.on_key_release(key, function(held_ms)
    local h = holds[key]
    holds[key] = nil
    -- moved away meanwhile: that move decides, leave it be
    if not (h and vim.api.nvim_get_current_win() == h.win and M.current_source() == h.arrived) then
      return
    end
    if held_ms >= PEEK_MS then
      unpeek(h)
    else
      record_jump(h)
    end
  end)
end

--- The jump of a press of `key`: `jump(mods)` moves the current window,
--- prefixing its commands with the modifiers `mods`. A watched key's jump
--- leaves the jumplist alone until the release tells a tap (recorded then) from
--- a peek (never recorded).
---@param key string
---@param jump fun(mods: string)
---@param left_insert boolean? Insert mode was left for the jump: a peek comes back to it
function M.jump(key, jump, left_insert)
  if holds[key] then return end -- a key repeat of the held key
  local win, src, buf = vim.api.nvim_get_current_win(), M.current_source(), vim.api.nvim_get_current_buf()
  local start = {
    win = win,
    buf = buf,
    cursor = vim.api.nvim_win_get_cursor(win),
    src = src,
    view = src == buf and vim.fn.winsaveview() or nil,
    alt = vim.fn.bufnr("#"),
    left_insert = left_insert,
  }
  jump(watched[key] and "keepjumps " or "")
  if watched[key] and vim.api.nvim_get_current_win() == win and M.current_source() ~= src then
    start.arrived = M.current_source()
    holds[key] = start
  end
end

return M
