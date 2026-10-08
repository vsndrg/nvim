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

-- Buffer whose file the current window shows: a preview view stands for its
-- markdown source (mdpreview is loaded lazily; without it there are no views).
local function current_source()
  local buf = vim.api.nvim_get_current_buf()
  local mdpreview = package.loaded["mdpreview"]
  return mdpreview and mdpreview.source_of(buf) or buf
end

local function same_file(a, b)
  return (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

-- Buffer the last jump to the pinned file started from.
local came_from

-- Open the pinned file of this project; fall back to the picker.
function M.open_pinned()
  local pinned = get_pin()
  if not pinned then
    vim.notify("No pinned .md in " .. vim.fn.getcwd())
    return M.pick()
  end
  if not vim.uv.fs_stat(pinned) then
    vim.notify("Pinned .md is gone: " .. pinned, vim.log.levels.WARN)
    return M.pick()
  end
  local src = current_source()
  if same_file(vim.api.nvim_buf_get_name(src), pinned) then return end
  came_from = src
  vim.cmd.edit(vim.fn.fnameescape(pinned))
end

-- On the pinned file: go back to where the jump came from; elsewhere: jump.
function M.toggle_pinned()
  local pinned = get_pin()
  if not (pinned and same_file(vim.api.nvim_buf_get_name(current_source()), pinned)) then
    return M.open_pinned()
  end
  if came_from and vim.api.nvim_buf_is_valid(came_from) and vim.bo[came_from].buflisted then
    vim.cmd.buffer(came_from)
  elseif vim.fn.bufnr("#") ~= -1 then
    vim.cmd("edit #")
  else
    vim.notify("Nowhere to go back from the pinned .md")
  end
end

return M
