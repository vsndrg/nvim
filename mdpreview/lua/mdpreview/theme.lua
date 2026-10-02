-- Preview themes: "github", "vscode" (both light/dark by 'background') and
-- "colorscheme" (CSS variables derived from the current highlight groups).
local M = {}

M.names = { "github", "vscode", "colorscheme" }

local state_file = vim.fn.stdpath("state") .. "/mdpreview.json"

function M.load_choice()
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
  end)
  if ok and type(data) == "table" and vim.tbl_contains(M.names, data.theme) then
    return data.theme
  end
  return "github"
end

function M.save_choice(name)
  pcall(vim.fn.writefile, { vim.json.encode({ theme = name }) }, state_file)
end

function M.next(name)
  for i, n in ipairs(M.names) do
    if n == name then
      return M.names[i % #M.names + 1]
    end
  end
  return M.names[1]
end

local function hex(n)
  return n and string.format("#%06x", n) or nil
end

-- First defined attribute among the given highlight groups (links resolved).
local function pick(attr, ...)
  for _, group in ipairs({ ... }) do
    local h = vim.api.nvim_get_hl(0, { name = group, link = false })
    if h[attr] then
      return hex(h[attr]), h
    end
  end
end

local function rgb(c)
  return tonumber(c:sub(2, 3), 16), tonumber(c:sub(4, 5), 16), tonumber(c:sub(6, 7), 16)
end

-- Blend colour `b` over `a` with weight t.
local function mix(a, b, t)
  local r1, g1, b1 = rgb(a)
  local r2, g2, b2 = rgb(b)
  local function m(x, y)
    return math.floor(x + (y - x) * t + 0.5)
  end
  return string.format("#%02x%02x%02x", m(r1, r2), m(g1, g2), m(b1, b2))
end

local function mono_font()
  local font = vim.o.guifont
  if font == "" then
    return nil
  end
  local family = font:match("^([^:,]+)")
  if not family then
    return nil
  end
  family = family:gsub("\\ ", " "):gsub("_", " ")
  return string.format('"%s", ui-monospace, SFMono-Regular, Menlo, monospace', family)
end

local function colorscheme_vars()
  local dark = vim.o.background == "dark"
  local bg = pick("bg", "Normal") or (dark and "#1e1e1e" or "#ffffff")
  local fg = pick("fg", "Normal") or (dark and "#d4d4d4" or "#1f2328")
  local accent = pick("fg", "@markup.link.url", "@markup.link", "Underlined", "Function", "Directory") or fg
  local success = pick("fg", "DiagnosticOk", "String") or fg
  local attention = pick("fg", "DiagnosticWarn", "WarningMsg") or fg
  local danger = pick("fg", "DiagnosticError", "ErrorMsg") or fg
  local done = pick("fg", "@keyword", "Statement") or accent

  local muted_bg
  for _, group in ipairs({ "NormalFloat", "Pmenu", "CursorLine", "ColorColumn" }) do
    local c = pick("bg", group)
    if c and c ~= bg then
      muted_bg = c
      break
    end
  end
  muted_bg = muted_bg or mix(bg, fg, 0.06)

  local comment, comment_hl = pick("fg", "@comment", "Comment")
  local border = pick("fg", "WinSeparator", "VertSplit")
  if not border or border == bg then
    border = mix(bg, fg, 0.2)
  end

  return {
    ["--cs-color-scheme"] = dark and "dark" or "light",
    ["--cs-bg"] = bg,
    ["--cs-fg"] = fg,
    ["--cs-fg-muted"] = comment or mix(fg, bg, 0.4),
    ["--cs-accent"] = accent,
    ["--cs-heading"] = pick("fg", "@markup.heading", "Title") or accent,
    ["--cs-success"] = success,
    ["--cs-attention"] = attention,
    ["--cs-danger"] = danger,
    ["--cs-done"] = done,
    ["--cs-bg-muted"] = muted_bg,
    ["--cs-bg-neutral"] = mix(bg, fg, 0.12),
    ["--cs-bg-attention"] = mix(bg, attention, 0.18),
    ["--cs-bg-danger"] = mix(bg, danger, 0.18),
    ["--cs-bg-success"] = mix(bg, success, 0.18),
    ["--cs-border"] = border,
    ["--cs-selection"] = pick("bg", "Visual") or mix(bg, accent, 0.3),
    ["--cs-search"] = pick("bg", "Search") or mix(bg, attention, 0.4),
    ["--cs-cur-search"] = pick("bg", "CurSearch", "IncSearch") or attention,
    ["--cs-code-fg"] = pick("fg", "@markup.raw", "String") or fg,
    ["--cs-mono-font"] = mono_font(),
    ["--cs-hl-fg"] = fg,
    ["--cs-hl-keyword"] = pick("fg", "@keyword", "Keyword", "Statement") or fg,
    ["--cs-hl-type"] = pick("fg", "@type", "Type") or fg,
    ["--cs-hl-function"] = pick("fg", "@function", "Function") or fg,
    ["--cs-hl-constant"] = pick("fg", "@constant", "Constant") or fg,
    ["--cs-hl-number"] = pick("fg", "@number", "Number") or fg,
    ["--cs-hl-string"] = pick("fg", "@string", "String") or fg,
    ["--cs-hl-regexp"] = pick("fg", "@string.regexp", "@string.special", "SpecialChar") or fg,
    ["--cs-hl-builtin"] = pick("fg", "@function.builtin", "@variable.builtin", "Special") or fg,
    ["--cs-hl-variable"] = pick("fg", "@variable.member", "@property", "Identifier") or fg,
    ["--cs-hl-comment"] = comment or fg,
    ["--cs-hl-comment-style"] = comment_hl and comment_hl.italic and "italic" or "normal",
    ["--cs-hl-tag"] = pick("fg", "@tag", "Tag") or fg,
    ["--cs-hl-attr"] = pick("fg", "@tag.attribute", "@attribute", "Identifier") or fg,
    ["--cs-hl-list"] = pick("fg", "@markup.list", "Special") or fg,
  }
end

-- Message for the page: { type = "theme", name, mode, vars? }.
function M.message(name)
  local msg = { type = "theme", name = name, mode = vim.o.background == "light" and "light" or "dark" }
  if name == "colorscheme" then
    msg.vars = colorscheme_vars()
  end
  return msg
end

return M
