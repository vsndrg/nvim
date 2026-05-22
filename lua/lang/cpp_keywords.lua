-- blink.cmp source providing C / C++ language keywords that clangd does NOT
-- reliably emit as completion candidates (control flow, exceptions, access
-- specifiers, declaration keywords, modern C++ tokens, casts).
--
-- Builtin types (`void`, `int`, `bool`, …) and type qualifiers (`const`,
-- `volatile`, `static`, …) are intentionally NOT listed here — clangd already
-- emits those, and including them would produce duplicate entries.
--
-- Items are emitted as CompletionItemKind.Keyword for the correct icon.

local CPP_BASE_KEYWORDS = {
  -- control flow
  "if", "else", "for", "while", "do", "switch", "case", "default",
  "break", "continue", "return", "goto",
  -- exceptions
  "try", "catch", "throw",
  -- literals / refs
  "true", "false", "this", "nullptr",
  -- operators / type ops
  "sizeof", "alignof", "alignas", "new", "delete", "operator", "decltype",
  -- access
  "private", "public", "protected",
  -- declarations
  "class", "struct", "union", "enum", "namespace", "using", "typedef",
  "template", "typename", "friend", "virtual", "override", "final",
  "explicit", "noexcept",
  -- modern C++ (20/23)
  "consteval", "constinit", "co_await", "co_yield", "co_return",
  "import", "export", "module", "requires", "concept",
  -- casts
  "static_cast", "dynamic_cast", "const_cast", "reinterpret_cast",
}

local C_BASE_KEYWORDS = {
  "if", "else", "for", "while", "do", "switch", "case", "default",
  "break", "continue", "return", "goto",
  "true", "false", "NULL",
  "sizeof", "alignof", "_Alignof", "_Alignas",
  "struct", "union", "enum", "typedef",
}

local KEYWORD_KIND = vim.lsp.protocol.CompletionItemKind.Keyword

local function build_items(list)
  local items = {}
  for _, kw in ipairs(list) do
    items[#items + 1] = {
      label = kw,
      kind = KEYWORD_KIND,
      insertText = kw,
    }
  end
  return items
end

local CPP_ITEMS = build_items(CPP_BASE_KEYWORDS)
local C_ITEMS   = build_items(C_BASE_KEYWORDS)

local CPP_FTS = { c = true, cpp = true, objc = true, objcpp = true, cuda = true }

local Source = {}
Source.__index = Source

function Source.new()
  return setmetatable({}, Source)
end

function Source:enabled()
  return CPP_FTS[vim.bo.filetype] == true
end

function Source:get_completions(_, callback)
  local items = (vim.bo.filetype == "c") and C_ITEMS or CPP_ITEMS
  callback({
    items = items,
    is_incomplete_backward = false,
    is_incomplete_forward = false,
  })
  return function() end
end

return Source
