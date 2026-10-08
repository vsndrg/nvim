-- Markdown files of the current project (cwd): a Telescope picker over *.md and
-- one pinned file per project that can be opened without the picker.
-- Pins live in stdpath("data")/md_pins.json as { [cwd] = absolute path }.
local M = {}

local store = vim.fn.stdpath("data") .. "/md_pins.json"
local mark = "  ★"

local function read_pins()
  local f = io.open(store, "r")
  if not f then return {} end
  local ok, pins = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(pins) == "table" and pins or {}
end

local function write_pins(pins)
  local f, err = io.open(store, "w")
  if not f then
    vim.notify("md pin: " .. err, vim.log.levels.ERROR)
    return
  end
  f:write(vim.json.encode(pins))
  f:close()
end

local function get_pin()
  return read_pins()[vim.fn.getcwd()]
end

local function set_pin(path)
  local pins = read_pins()
  pins[vim.fn.getcwd()] = path
  write_pins(pins)
end

-- *.md files under cwd, gitignored ones included (node_modules etc. are still
-- dropped by telescope's file_ignore_patterns); the pinned one first so it is
-- the default selection.
local function list_files(pinned)
  -- fd, not rg: an rg --type/--glob whitelist also lets hidden files through
  local files = vim.fn.systemlist({ "fd", "--type", "f", "--extension", "md", "--no-ignore-vcs" })
  table.sort(files)
  local cwd = vim.fn.getcwd()
  for i, rel in ipairs(files) do
    if vim.fs.joinpath(cwd, rel) == pinned then
      table.remove(files, i)
      table.insert(files, 1, rel)
      break
    end
  end
  return files
end

local function make_finder(opts)
  local finders = require("telescope.finders")
  local base = require("telescope.make_entry").gen_from_file(opts)
  local pinned = get_pin()
  return finders.new_table({
    results = list_files(pinned),
    entry_maker = function(line)
      local entry = base(line)
      if entry.path == pinned then
        -- appended, not prefixed: devicon/path highlights keep their offsets
        local display = getmetatable(entry).display
        entry.display = function(e)
          local text, style = display(e)
          return text .. mark, style
        end
      end
      return entry
    end,
  })
end

function M.pick()
  local action_state = require("telescope.actions.state")
  local opts = { cwd = vim.fn.getcwd() }

  -- Pin the selected file, or unpin it if it is already pinned.
  local function toggle_pin(prompt_bufnr)
    local entry = action_state.get_selected_entry()
    if not entry then return end
    if entry.path == get_pin() then
      set_pin(nil)
      vim.notify("md pin removed")
    else
      set_pin(entry.path)
      vim.notify("md pinned: " .. entry.value)
    end
    action_state.get_current_picker(prompt_bufnr):refresh(make_finder(opts), { reset_prompt = false })
  end

  require("telescope.pickers").new(opts, {
    prompt_title = "Markdown files",
    initial_mode = "normal",
    finder = make_finder(opts),
    sorter = require("telescope.config").values.file_sorter(opts),
    previewer = require("telescope.config").values.file_previewer(opts),
    attach_mappings = function(_, map)
      -- nowait: both keys prefix global maps (nvim-surround's i_<C-g>s,
      -- marks.nvim's m1/m,/m;...), which would hold them for 'timeoutlen'
      map({ "i", "n" }, "<C-g>", toggle_pin, { nowait = true })
      map("n", "m", toggle_pin, { nowait = true })
      return true
    end,
  }):find()
end

local peek = require("utils.peek")

local function same_file(a, b)
  return (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

-- Where the last jump to the pinned file started from: the source buffer and,
-- unless it was a preview, its view.
local came_from

-- `mods`: command modifiers for the jump (see utils.peek).
local function jump_to_pinned(mods)
  local pinned = get_pin()
  if not pinned then
    vim.notify("No pinned .md in " .. vim.fn.getcwd())
    return M.pick()
  end
  if not vim.uv.fs_stat(pinned) then
    vim.notify("Pinned .md is gone: " .. pinned, vim.log.levels.WARN)
    return M.pick()
  end
  local src = peek.current_source()
  if same_file(vim.api.nvim_buf_get_name(src), pinned) then return end
  came_from = {
    buf = src,
    view = src == vim.api.nvim_get_current_buf() and vim.fn.winsaveview() or nil,
  }
  vim.cmd(mods .. "edit " .. vim.fn.fnameescape(pinned))
end

-- Open the pinned file of this project; fall back to the picker.
function M.open_pinned()
  jump_to_pinned("")
end

local function go_back(mods)
  if came_from and vim.api.nvim_buf_is_valid(came_from.buf) and vim.bo[came_from.buf].buflisted then
    vim.cmd(mods .. "buffer " .. came_from.buf)
    if came_from.view then vim.fn.winrestview(came_from.view) end
  elseif vim.fn.bufnr("#") ~= -1 then
    vim.cmd(mods .. "edit #")
  else
    vim.notify("Nowhere to go back from the pinned .md")
  end
end

peek.watch("<C-m>")

-- On the pinned file: go back to where the jump came from; elsewhere: jump.
-- Held, it peeks (utils.peek). `from_insert`: Insert mode was left for it.
function M.toggle_pinned(from_insert)
  peek.jump("<C-m>", function(mods)
    local pinned = get_pin()
    if pinned and same_file(vim.api.nvim_buf_get_name(peek.current_source()), pinned) then
      go_back(mods)
    else
      jump_to_pinned(mods)
    end
  end, from_insert)
end

-- Ctrl+M is a file key only in windows that show a file (or its preview);
-- elsewhere (floats, quickfix, prompts) it stays Enter.
local function in_file_window()
  if vim.api.nvim_win_get_config(0).relative ~= "" then return false end
  local buf = vim.api.nvim_get_current_buf()
  return vim.bo[buf].buftype == "" or peek.current_source() ~= buf
end

-- Leaves Insert mode with the built-in <Esc> (not remapped: blink.cmp's
-- buffer-local <Esc> would leave it only after the jump, in the other buffer).
vim.keymap.set("i", "<Plug>(md-files-toggle)", "<Esc><Cmd>lua require('utils.md_files').toggle_pinned(true)<CR>")

-- rhs for `<C-m>` (expr, remap): <CR> outside file windows reaches buffer-local
-- <CR> maps.
function M.ctrl_m(insert)
  if not in_file_window() then return "<CR>" end
  if insert then return "<Plug>(md-files-toggle)" end
  return "<Cmd>lua require('utils.md_files').toggle_pinned(false)<CR>"
end

return M
