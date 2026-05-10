-- tuProlog REPL backend.
--
-- Поднимает Java subprocess `TuPrologRepl` (см. соседний repl/TuPrologRepl.java)
-- и общается с ним по stdin/stdout. Каждый ответ заканчивается маркером
-- "<<<END>>>" — это позволяет соотнести ответы с поставленными запросами.

local M = {}

local END_MARKER = "<<<END>>>"

local state = {
  job_id = nil,
  jar_path = nil,
  callbacks = {},   -- очередь {fn(string)} — по одной на каждую отправленную команду
  current = {},     -- собирающийся блок ответа (массив строк)
  partial = "",     -- незавершённая последняя строка из jobstart
  global_listener = nil,
}

local function find_jar_in(dir)
  local hits = vim.fn.glob(dir .. "/lib/2p-*.jar", false, true)
  vim.list_extend(hits, vim.fn.glob(dir .. "/2p-*.jar", false, true))
  if hits[1] then return hits[1] end
  return nil
end

function M.find_jar()
  if vim.g.tuprolog_jar and vim.fn.filereadable(vim.g.tuprolog_jar) == 1 then
    return vim.g.tuprolog_jar
  end
  local dir = vim.fn.getcwd()
  while dir and dir ~= "" and dir ~= "/" do
    local jar = find_jar_in(dir)
    if jar then return jar end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  local fallback = vim.fn.expand("~/Home/itmo/pi/hw/paradigms-2026/prolog/lib/2p-4.0.3.jar")
  if vim.fn.filereadable(fallback) == 1 then return fallback end
  return nil
end

local function compile_helper(jar_path)
  local config_dir = vim.fn.stdpath("config")
  local src = config_dir .. "/lua/prolog/repl/TuPrologRepl.java"
  if vim.fn.filereadable(src) == 0 then
    vim.notify("TuPrologRepl.java не найден: " .. src, vim.log.levels.ERROR)
    return nil
  end
  local cache = vim.fn.stdpath("cache") .. "/prolog"
  vim.fn.mkdir(cache, "p")
  local class_file = cache .. "/TuPrologRepl.class"

  local need = vim.fn.filereadable(class_file) == 0
  if not need then
    if vim.fn.getftime(src) > vim.fn.getftime(class_file) then need = true end
  end
  if need then
    local out = vim.fn.system({ "javac", "-cp", jar_path, "-d", cache, src })
    if vim.v.shell_error ~= 0 then
      vim.notify("javac failed:\n" .. out, vim.log.levels.ERROR)
      return nil
    end
  end
  return cache
end

local function flush_block()
  local block = table.concat(state.current, "\n")
  state.current = {}
  local cb = table.remove(state.callbacks, 1)
  if cb then pcall(cb, block) end
  if state.global_listener then pcall(state.global_listener, block) end
end

local function on_line(line)
  if line == END_MARKER then
    flush_block()
  else
    table.insert(state.current, line)
  end
end

local function on_stdout(_, data, _)
  if not data then return end
  -- jobstart: data — массив строк, первый элемент склеивается с предыдущим хвостом,
  -- последний может быть неполной строкой (если не завершается \n).
  data[1] = state.partial .. data[1]
  state.partial = data[#data]
  for i = 1, #data - 1 do
    on_line(data[i])
  end
end

local function on_stderr(_, data, _)
  if not data then return end
  for _, line in ipairs(data) do
    if line ~= "" then
      vim.schedule(function()
        vim.notify("[tuprolog] " .. line, vim.log.levels.WARN)
      end)
    end
  end
end

local function on_exit(_, code, _)
  state.job_id = nil
  state.callbacks = {}
  state.current = {}
  state.partial = ""
  if code ~= 0 then
    vim.schedule(function()
      vim.notify("tuProlog REPL exited (code=" .. code .. ")", vim.log.levels.WARN)
    end)
  end
end

function M.start()
  if state.job_id then return true end

  local jar = M.find_jar()
  if not jar then
    vim.notify(
      "tuProlog jar не найден. Задай vim.g.tuprolog_jar = '/path/to/2p-X.Y.Z.jar' или положи 2p-*.jar в ./lib/",
      vim.log.levels.ERROR)
    return false
  end
  state.jar_path = jar

  local class_dir = compile_helper(jar)
  if not class_dir then return false end

  local cmd = { "java", "-Dfile.encoding=UTF-8", "-cp", jar .. ":" .. class_dir, "TuPrologRepl" }
  state.callbacks = {}
  state.current = {}
  state.partial = ""

  -- первый ответ ("tuProlog REPL ready.") приходит без отправки команды;
  -- резервируем под него «холостой» callback, иначе он бы съел callback
  -- от первого реального consult/query (race condition).
  state.callbacks = { function() end }

  state.job_id = vim.fn.jobstart(cmd, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
  })

  if state.job_id <= 0 then
    state.job_id = nil
    vim.notify("Не удалось запустить tuProlog REPL (jobstart=" .. tostring(state.job_id) .. ")", vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.stop()
  if state.job_id then
    pcall(vim.fn.jobstop, state.job_id)
    state.job_id = nil
  end
end

function M.is_running()
  return state.job_id ~= nil
end

function M.set_global_listener(fn)
  state.global_listener = fn
end

local function send_raw(text, on_done)
  if not M.start() then return end
  table.insert(state.callbacks, on_done or function() end)
  vim.fn.chansend(state.job_id, text .. "\n")
end

function M.consult(path, on_done)
  send_raw(":consult " .. path, on_done)
end

function M.query(text, on_done)
  send_raw(text, on_done)
end

function M.next(on_done)
  send_raw(":next", on_done)
end

function M.stop_solve(on_done)
  send_raw(":stop", on_done)
end

function M.trace(enable, on_done)
  send_raw(":trace " .. (enable and "on" or "off"), on_done)
end

function M.spy(pred, on_done)
  send_raw(":spy " .. pred, on_done)
end

function M.nospy(pred, on_done)
  send_raw(":nospy " .. pred, on_done)
end

function M.reset(on_done)
  send_raw(":reset", on_done)
end

return M
