-- blink.cmp source providing C / C++ language keywords.
--
-- Surfaces them as CompletionItemKind.Keyword so the global IDE-style ranking
-- (kind_weight: Keyword=4) puts them above clangd's index-derived Variables and
-- Functions. clangd does not reliably emit `for`, `private`, etc. as completion
-- candidates in all contexts; this source guarantees they always show up.

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
  -- type qualifiers / storage
  "const", "volatile", "mutable", "static", "extern", "inline", "constexpr",
  "thread_local", "auto", "register",
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
  -- builtin types
  "bool", "char", "char8_t", "char16_t", "char32_t", "wchar_t",
  "short", "int", "long", "float", "double", "signed", "unsigned", "void",
  "size_t", "ptrdiff_t", "nullptr_t",
}

local C_BASE_KEYWORDS = {
  "if", "else", "for", "while", "do", "switch", "case", "default",
  "break", "continue", "return", "goto",
  "true", "false", "NULL",
  "sizeof", "alignof", "_Alignof", "_Alignas",
  "const", "volatile", "restrict", "static", "extern", "inline", "auto",
  "register", "_Thread_local", "_Atomic", "_Noreturn",
  "struct", "union", "enum", "typedef",
  "bool", "_Bool", "char", "short", "int", "long", "float", "double",
  "signed", "unsigned", "void", "size_t", "ptrdiff_t",
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
