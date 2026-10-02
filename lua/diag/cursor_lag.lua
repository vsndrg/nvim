-- Cursor-lag recorder.
--
-- Diagnoses the intermittent "holding h/j/k/l moves the cursor slowly" issue.
-- Benchmarks showed Neovim itself costs <=1.1 ms per motion while macOS key
-- repeat (KeyRepeat=1) delivers one key every ~15 ms, so the editor has ~15x
-- headroom. That means the slowdown has to be either (a) keys not reaching
-- Neovim at the repeat rate, (b) the main loop blocking, or (c) purely visual
-- lag in Neovide's renderer. Those three are indistinguishable by eye, so we
-- record the evidence at the moment it happens instead of guessing afterwards.
--
-- Cost at rest is zero: the sampling timer only runs while motion keys are
-- actually being held, and stops 2 s after the burst ends.
--
--   :LagReport   dump the last window on demand
--   :LagStatus   show recorder state
--   :LagWatch    toggle auto-capture (on by default)
--
-- Reports are appended to ~/.local/state/nvim/cursor-lag.log

local M = {}

local MOTION = { h = true, j = true, k = true, l = true }

local WINDOW_NS = 5e9  -- how much history a report covers
local RETAIN_NS = 12e9 -- how much history is kept, so :LagReport can be run
                       -- a few seconds after a burst instead of during it
local SAMPLE_MS = 20  -- main-loop probe interval while recording
local IDLE_STOP_MS = 2000
local COOLDOWN_NS = 8e9 -- min gap between two auto-captures

-- Expected inter-key gap from the OS key-repeat setting. macOS reports
-- KeyRepeat in units of 15 ms; we read it once at startup.
local expected_gap_ms = 15

local keys = {}     -- { t = hrtime, key = "j" }
local moves = {}    -- { t = hrtime, latency_ms = <key -> CursorMoved> }
local lags = {}     -- { t = hrtime, lag_ms = <main-loop probe overrun> }

local recording = false
local timer = nil
local last_probe = 0
local last_motion_t = 0
local pending_key = nil -- last motion key not yet matched to a CursorMoved
local last_capture_t = 0
local watching = true
local captures = 0 -- reports written this session; auto ones are silent

local logfile = vim.fs.joinpath(vim.fn.stdpath("state"), "cursor-lag.log")

local function now() return vim.uv.hrtime() end

local function trim(buf, cutoff)
  if #buf < 400 then return end
  local out, n = {}, 0
  for i = 1, #buf do
    if buf[i].t >= cutoff then n = n + 1; out[n] = buf[i] end
  end
  return out
end

local function trim_all()
  local cutoff = now() - RETAIN_NS
  keys = trim(keys, cutoff) or keys
  moves = trim(moves, cutoff) or moves
  lags = trim(lags, cutoff) or lags
end

---------------------------------------------------------------------------
-- recording lifecycle
---------------------------------------------------------------------------

local function stop_recording()
  if timer then timer:stop(); timer:close(); timer = nil end
  recording = false
end

local function start_recording()
  if recording then return end
  recording = true
  last_probe = now()
  timer = vim.uv.new_timer()
  timer:start(SAMPLE_MS, SAMPLE_MS, vim.schedule_wrap(function()
    local t = now()
    -- Overrun of a fixed-interval timer == time the main loop was unavailable.
    -- This also catches UI backpressure: if Neovide is slow to drain the
    -- redraw stream, Neovim's writes stall here.
    local lag = (t - last_probe) / 1e6 - SAMPLE_MS
    last_probe = t
    if lag > 2 then lags[#lags + 1] = { t = t, lag_ms = lag } end

    if (t - last_motion_t) / 1e6 > IDLE_STOP_MS then stop_recording() end
  end))
end

---------------------------------------------------------------------------
-- statistics
---------------------------------------------------------------------------

local function percentile(values, p)
  if #values == 0 then return 0 end
  local copy = vim.deepcopy(values)
  table.sort(copy)
  local idx = math.max(1, math.ceil(#copy * p))
  return copy[idx]
end

local function collect(window_ns)
  local cutoff = now() - (window_ns or WINDOW_NS)

  local gaps, latencies, lag_values = {}, {}, {}
  local nkeys, nmoves = 0, 0
  local prev_t, first_t, last_t = nil, nil, nil

  for _, e in ipairs(keys) do
    if e.t >= cutoff then
      nkeys = nkeys + 1
      first_t = first_t or e.t
      last_t = e.t
      if prev_t then gaps[#gaps + 1] = (e.t - prev_t) / 1e6 end
      prev_t = e.t
    end
  end
  for _, e in ipairs(moves) do
    if e.t >= cutoff then
      nmoves = nmoves + 1
      if e.latency_ms then latencies[#latencies + 1] = e.latency_ms end
    end
  end
  for _, e in ipairs(lags) do
    if e.t >= cutoff then lag_values[#lag_values + 1] = e.lag_ms end
  end

  -- Rates must be measured over the actual burst, not over the fixed window,
  -- otherwise a 0.9 s hold inside a 3 s window reports a third of the real rate.
  local span_s = (first_t and last_t and last_t > first_t)
    and (last_t - first_t) / 1e9
    or (window_ns or WINDOW_NS) / 1e9
  return {
    keys = nkeys,
    moves = nmoves,
    gaps = gaps,
    span_s = span_s,
    keys_per_sec = nkeys / span_s,
    moves_per_sec = nmoves / span_s,
    -- p10 is the burst's own fastest sustained gap, i.e. the rate this machine
    -- actually delivers when nothing is wrong. Measured baseline is 16.7 ms
    -- (60 Hz), not the 15 ms implied by KeyRepeat=1, so thresholds are derived
    -- from observation rather than from the OS setting.
    gap_p10 = percentile(gaps, 0.10),
    gap_p50 = percentile(gaps, 0.5),
    gap_p95 = percentile(gaps, 0.95),
    lat_p50 = percentile(latencies, 0.5),
    lat_p95 = percentile(latencies, 0.95),
    lat_max = percentile(latencies, 1.0),
    lag_max = percentile(lag_values, 1.0),
    lag_sum = (function() local s = 0; for _, v in ipairs(lag_values) do s = s + v end; return s end)(),
    lag_count = #lag_values,
  }
end

-- Raw gap distribution. Deliberately NOT auto-classified: the two candidate
-- explanations (frame-locked delivery at 30 Hz = 33.3 ms vs dropped key
-- repeats = 2x15 ms) sit ~3 ms apart, which is inside this recorder's noise.
-- A curve fit between them looks decisive and is not, so the histogram is
-- reported as-is and the question is settled by experiment instead.
local function histogram(gaps)
  if #gaps == 0 then return {} end
  local bins, maxc = {}, 0
  for _, g in ipairs(gaps) do
    local b = math.floor(g / 2) * 2
    bins[b] = (bins[b] or 0) + 1
    if bins[b] > maxc then maxc = bins[b] end
  end
  local ordered = vim.tbl_keys(bins)
  table.sort(ordered)
  local lines = {}
  for _, b in ipairs(ordered) do
    local c = bins[b]
    lines[#lines + 1] = ("    %5.1f-%4.1f ms | %-30s %d"):format(
      b, b + 2, string.rep("#", math.ceil(c / maxc * 30)), c)
  end
  return lines
end

-- The whole point of the recorder: say which of the three candidates it was.
local function verdict(s)
  local lines = {}
  -- The observed failure is an exact doubling of the gap (33.4 ms against a
  -- 16.7 ms baseline): every second key repeat goes missing. Comparing p50
  -- against this burst's own p10 detects that without assuming a fixed rate.
  local ratio = s.gap_p10 > 0 and s.gap_p50 / s.gap_p10 or 1
  local slow_input = ratio > 1.7
  local blocked = s.lag_max > 25
  local slow_nvim = s.lat_p95 > 5

  if s.keys < 15 then
    lines[#lines + 1] = "  (too few motion keys in window - hold h/j/k/l longer)"
    return lines
  end

  -- Without CursorMoved pairing there is no latency signal, and claiming
  -- "nvim kept up in 0.00 ms" from missing data would be a false verdict.
  if s.moves == 0 then
    lines[#lines + 1] = "  INCOMPLETE: no CursorMoved fired for these keys - latency could not be measured."
    lines[#lines + 1] = ("  input gap p50=%.1f ms, loop worst=%.0f ms (these are still valid)."):format(s.gap_p50, s.lag_max)
    return lines
  end

  if slow_input then
    lines[#lines + 1] = ("  INPUT: gap p50 %.1f ms is %.2fx this burst's own fastest rate (%.1f ms)."):format(
      s.gap_p50, ratio, s.gap_p10)
    if blocked then
      lines[#lines + 1] = ("  -> main loop blocked up to %.0f ms; Neovim (or UI backpressure) is holding input back."):format(s.lag_max)
    else
      lines[#lines + 1] = "  -> main loop was free, so keys are lost/delayed before Neovim: Neovide input path or the OS."
    end
    if ratio > 1.8 and ratio < 2.2 then
      lines[#lines + 1] = "  -> exactly half rate: every second key repeat is being dropped."
    end
    lines[#lines + 1] = ("  effective rate %.0f keys/s (baseline would be %.0f/s)."):format(
      s.keys_per_sec, 1000 / math.max(s.gap_p10, 1))
  elseif slow_nvim then
    lines[#lines + 1] = ("  NVIM: key->CursorMoved p95 = %.2f ms (max %.2f). Neovim itself is slow on this buffer."):format(s.lat_p95, s.lat_max)
  elseif blocked then
    lines[#lines + 1] = ("  BLOCKED: input rate is fine but main loop stalled up to %.0f ms (%d stalls, %.0f ms total)."):format(s.lag_max, s.lag_count, s.lag_sum)
  else
    lines[#lines + 1] = ("  RENDER: Neovim received %.0f keys/s and processed every one in %.2f ms (p95)."):format(s.keys_per_sec, s.lat_p95)
    lines[#lines + 1] = "  -> Neovim kept up fully. If the cursor looked slow, the lag is in Neovide's renderer/cursor animation."
  end
  return lines
end

---------------------------------------------------------------------------
-- reporting
---------------------------------------------------------------------------

local function append(text)
  local f = io.open(logfile, "a")
  if not f then return end
  f:write(text .. "\n")
  f:close()
end

local function report(reason)
  local s = collect()
  local buf = vim.api.nvim_get_current_buf()
  local clients = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do clients[#clients + 1] = c.name end

  local head = {
    "",
    ("=== cursor-lag %s | %s ==="):format(reason, os.date("%Y-%m-%d %H:%M:%S")),
    -- Which GUI produced the sample. Comparing Neovide against a terminal
    -- frontend is the only way to tell a Neovide input problem from an
    -- OS/Karabiner one, so every capture has to say where it came from.
    ("frontend: %s"):format(vim.g.neovide
      and ("neovide " .. tostring(vim.g.neovide_version))
      or ("terminal " .. (vim.env.TERM_PROGRAM or vim.env.TERM or "?"))),
    ("buffer: %s  ft=%s  lines=%d  lsp=[%s]"):format(
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:."),
      vim.bo[buf].filetype,
      vim.api.nvim_buf_line_count(buf),
      table.concat(clients, ",")),
    ("input:  %d keys over %.2f s (%.0f/s)  gap p10=%.1f p50=%.1f p95=%.1f ms  (OS setting implies ~%d ms)"):format(
      s.keys, s.span_s, s.keys_per_sec, s.gap_p10, s.gap_p50, s.gap_p95, expected_gap_ms),
    ("nvim:   %d CursorMoved (%.0f/s)  key->moved p50=%.2f ms  p95=%.2f ms  max=%.2f ms"):format(
      s.moves, s.moves_per_sec, s.lat_p50, s.lat_p95, s.lat_max),
    ("loop:   %d stalls >2 ms  total=%.0f ms  worst=%.0f ms"):format(s.lag_count, s.lag_sum, s.lag_max),
    "key-gap histogram:",
  }
  vim.list_extend(head, histogram(s.gaps))
  head[#head + 1] = "verdict:"
  vim.list_extend(head, verdict(s))
  local text = table.concat(head, "\n")
  append(text)
  captures = captures + 1

  -- Auto-captures fire while you are working and must stay silent: popping a
  -- full report interrupts the very session being measured. Only an explicit
  -- :LagReport shows anything. Use :LagStatus to see what has been recorded.
  if reason == "MANUAL" then
    -- The log entry starts with a blank separator line; strip it so the
    -- notification does not open with an empty row.
    vim.notify(vim.trim(text), vim.log.levels.INFO)
  end

  -- External state is fetched asynchronously so the report itself never blocks.
  vim.system({ "sh", "-c",
    "ps -Ao pcpu,rss,comm | sort -rn | head -8; " ..
    "echo '--- thermal ---'; pmset -g therm 2>/dev/null | head -5; " ..
    "echo '--- load ---'; sysctl -n vm.loadavg"
  }, { text = true }, function(res)
    append("system state at capture:\n" .. (res.stdout or "") .. (res.stderr or ""))
  end)
end

---------------------------------------------------------------------------
-- hooks
---------------------------------------------------------------------------

local function maybe_auto_capture()
  if not watching then return end
  local t = now()
  if t - last_capture_t < COOLDOWN_NS then return end
  local s = collect(1.5e9)
  -- Only judge sustained holds, never individual taps. 15 keys is ~0.5 s of
  -- holding even at the degraded half rate, so short episodes are caught too.
  if s.keys < 15 then return end
  local halved = s.gap_p10 > 0 and (s.gap_p50 / s.gap_p10) > 1.7
  if halved or s.lag_max > 25 or s.lat_p95 > 5 then
    last_capture_t = t
    vim.schedule(function() report("AUTO") end)
  end
end

function M.setup()
  -- Read the OS key-repeat setting once so the report compares against the
  -- rate the system is actually sending, not a hardcoded guess.
  vim.system({ "defaults", "read", "-g", "KeyRepeat" }, { text = true }, function(res)
    local n = tonumber((res.stdout or ""):match("%d+"))
    if n then expected_gap_ms = n * 15 end
  end)

  local ns = vim.api.nvim_create_namespace("cursor_lag")
  vim.on_key(function(key)
    -- Cheap filter first: this runs for every keystroke.
    if not MOTION[key] then return end
    if vim.api.nvim_get_mode().mode ~= "n" then return end
    local t = now()
    last_motion_t = t
    keys[#keys + 1] = { t = t, key = key }
    pending_key = t
    if not recording then start_recording() end
    if #keys > 3000 then trim_all() end
  end, ns)

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup("CursorLagRecorder", { clear = true }),
    callback = function()
      if not recording then return end
      local t = now()
      moves[#moves + 1] = {
        t = t,
        latency_ms = pending_key and (t - pending_key) / 1e6 or nil,
      }
      pending_key = nil
      maybe_auto_capture()
    end,
  })

  vim.api.nvim_create_user_command("LagReport", function() report("MANUAL") end,
    { desc = "Dump cursor-lag stats for the last 3 s" })

  vim.api.nvim_create_user_command("LagStatus", function()
    local s = collect()
    vim.notify(("cursor-lag: watching=%s recording=%s | captures this session: %d\nlast 5 s: %d keys, %d moves\nlog: %s")
      :format(tostring(watching), tostring(recording), captures, s.keys, s.moves, logfile))
  end, { desc = "Show cursor-lag recorder state" })

  vim.api.nvim_create_user_command("LagWatch", function()
    watching = not watching
    vim.notify("cursor-lag auto-capture: " .. (watching and "ON" or "OFF"))
  end, { desc = "Toggle cursor-lag auto-capture" })
end

return M
