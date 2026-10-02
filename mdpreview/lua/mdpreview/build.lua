-- Builds the web renderer (web/dist) with npm + esbuild.
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
M.web_dir = root .. "/web"
M.index = M.web_dir .. "/dist/index.html"

local running = false
local waiting = {}

function M.is_built()
  return vim.uv.fs_stat(M.index) ~= nil
end

local function finish(ok, err)
  running = false
  local callbacks = waiting
  waiting = {}
  if ok then
    vim.notify("mdpreview: renderer built", vim.log.levels.INFO)
  else
    vim.notify("mdpreview: build failed\n" .. (err or ""), vim.log.levels.ERROR)
  end
  for _, cb in ipairs(callbacks) do
    cb(ok)
  end
end

local function run(cmd, on_done)
  vim.system(cmd, { cwd = M.web_dir, text = true }, function(res)
    vim.schedule(function()
      on_done(res.code == 0, (res.stderr or "") .. (res.stdout or ""))
    end)
  end)
end

-- Runs `npm ci` (when node_modules is missing or `full`) and the build.
function M.build(full, cb)
  if cb then
    table.insert(waiting, cb)
  end
  if running then
    return
  end
  running = true
  vim.notify("mdpreview: building renderer…", vim.log.levels.INFO)
  local function build()
    run({ "node", "build.mjs" }, function(ok, out)
      finish(ok, not ok and out or nil)
    end)
  end
  if full or not vim.uv.fs_stat(M.web_dir .. "/node_modules") then
    run({ "npm", "ci", "--no-audit", "--no-fund" }, function(ok, out)
      if ok then
        build()
      else
        finish(false, out)
      end
    end)
  else
    build()
  end
end

function M.ensure(cb)
  if M.is_built() then
    cb(true)
  else
    M.build(false, cb)
  end
end

return M
