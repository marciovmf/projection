-- lua/projection/init.lua
-- projection.nvim: stream build/clean commands into the quickfix list in real time.
-- All comments and user-facing messages are in ENGLISH.

local M = {}

-- Default configuration
M.cfg = {
  -- Build/Clean commands (one can be nil):
  --   string -> executed via shell (respects pipes/redirects)
  --   table  -> argv list passed directly to jobstart (no shell)
  --   nil    -> for build: fallback to &makeprg or "make"; for clean: disabled
  build_cmd = nil,
  clean_cmd = nil,

  -- Quickfix opening strategy: 'horizontal' | 'vertical' | 'never'
  open = 'horizontal',

  -- Quickfix default sizes
  qf_height = 12,  -- when horizontal
  qf_width  = 50,  -- when vertical

  -- Equalize windows (Ctrl-W =) right after opening quickfix
  equalize = false,

  -- Show notifications at the end of the job
  notify = true,

  -- Timeout failsafe
  timeout_sec = 0,        -- 0 = disabled
  kill_grace_ms = 2000,   -- grace after soft stop before hard kill
  hard_kill_signal = 9,   -- SIGKILL by default

  -- Project name (visible in title bar and usable in statusline)
  project_name = nil,

  -- Optional keymaps (global, normal mode). Set to nil to skip.
  -- Examples: '<F9>', '<C-b>'
  build_key = nil,
  clean_key = nil,
}

local job_id = nil
local job_pid = nil
local timeout_timer = nil
local hardkill_timer = nil

-- Keep original titlestring to restore when project changes
M._orig_titlestring = nil
M._title_active = false

-- Track last applied keymaps so we can unmap when config changes
M._last_build_key = nil
M._last_clean_key = nil

-- Coerce common Vimscript literal strings into Lua booleans/numbers
local function coerce(v)
  if v == 'true'  or v == true  then return true end
  if v == 'false' or v == false then return false end
  if type(v) == 'string' then
    local n = tonumber(v)
    if n ~= nil then return n end
  end
  return v
end

-- Shallow merge "src" into "dst"
local function merge_into(dst, src)
  if type(src) ~= 'table' then return dst end
  for k, v in pairs(src) do
    dst[k] = coerce(v)
  end
  return dst
end

--- Setup global defaults (optional)
---@param opts table|nil
function M.setup(opts)
  if opts then merge_into(M.cfg, opts) end
  -- Apply project name and keymaps
  M._apply_project_name()
  M._apply_keymaps()
end

-- Consume g:projection (Vimscript or Lua)
function M.apply_global_var()
  local gv = vim.g.projection
  if type(gv) == 'table' then
    M.setup(gv)
  end
end

-- Upward search for a file from CWD
local function find_upwards(names)
  local uv = vim.loop
  local cwd = uv.cwd() or '.'
  local sep = package.config:sub(1,1)
  local function join(a,b) return a .. sep .. b end

  local dir = cwd
  local last = nil
  while dir and dir ~= last do
    for _, name in ipairs(names) do
      local p = join(dir, name)
      local stat = uv.fs_stat(p)
      if stat and stat.type == 'file' then
        return p
      end
    end
    last = dir
    local parent = dir:match('(.*)' .. vim.pesc(sep))
    if not parent or parent == '' then break end
    dir = parent
  end
  return nil
end

-- Project config loader: prioritize project.lua, fallback to legacy names
-- The file can:
--   * return a table of options
--   * or return a function(plugin) and call plugin.setup{...}
function M.load_project_config()
  local path = find_upwards({ 'project.lua', '.projection.lua', '.nvim/projection.lua' })
  if not path then
    -- No project file found, restore title and keymaps if previously set
    M._clear_project_name_effects()
    M._clear_keymaps()
    return false
  end
  local ok, chunk = pcall(loadfile, path)
  if not ok then
    vim.notify('[projection] failed loading project config: ' .. tostring(chunk), vim.log.levels.ERROR)
    return false
  end
  local ok2, ret = pcall(chunk)
  if not ok2 then
    vim.notify('[projection] project config error: ' .. tostring(ret), vim.log.levels.ERROR)
    return false
  end
  if type(ret) == 'table' then
    M.setup(ret)
    vim.b.projection_project_config = path
    return true
  elseif type(ret) == 'function' then
    pcall(ret, M)
    vim.b.projection_project_config = path
    return true
  end
  vim.b.projection_project_config = path
  -- Even if file returns nil, apply effects from current cfg
  M._apply_project_name()
  M._apply_keymaps()
  return true
end

-- ---- Project name visibility helpers ----

-- Return formatted status fragment (can be used in statusline)
function M.status()
  if M.cfg.project_name and tostring(M.cfg.project_name) ~= '' then
    return string.format('[%s]', tostring(M.cfg.project_name))
  end
  return ''
end

function M._clear_project_name_effects()
  if M._title_active and M._orig_titlestring ~= nil then
    vim.o.titlestring = M._orig_titlestring
    M._title_active = false
  end
end

function M._apply_project_name()
  -- Update title bar with project name if provided
  local name = M.cfg.project_name
  if name and tostring(name) ~= '' then
    if not M._title_active then
      M._orig_titlestring = vim.o.titlestring ~= '' and vim.o.titlestring or '%f - nvim'
    end
    vim.o.title = true
    vim.o.titlestring = string.format('[%s] %s', tostring(name), M._orig_titlestring or '%f - nvim')
    M._title_active = true
  else
    -- No project name: restore previous title
    M._clear_project_name_effects()
  end
end

-- ---- Keymap helpers ----

function M._clear_keymaps()
  if M._last_build_key then pcall(vim.keymap.del, 'n', M._last_build_key) end
  if M._last_clean_key then pcall(vim.keymap.del, 'n', M._last_clean_key) end
  M._last_build_key = nil
  M._last_clean_key = nil
end

function M._apply_keymaps()
  -- Clear old ones
  M._clear_keymaps()
  -- Build
  if M.cfg.build_key and tostring(M.cfg.build_key) ~= '' then
    vim.keymap.set('n', M.cfg.build_key, function() M.run_build() end,
      { desc = 'projection: build' })
    M._last_build_key = M.cfg.build_key
  end
  -- Clean
  if M.cfg.clean_key and tostring(M.cfg.clean_key) ~= '' then
    vim.keymap.set('n', M.cfg.clean_key, function() M.run_clean() end,
      { desc = 'projection: clean' })
    M._last_clean_key = M.cfg.clean_key
  end
end

-- Detect if a quickfix window is already open
local function has_qf_window()
  for _, win in ipairs(vim.fn.getwininfo()) do
    if win.quickfix == 1 then return true end
  end
  return false
end

-- Open quickfix according to config, without duplicating windows
local function open_qf_if_needed(cfg)
  if cfg.open == 'never' or has_qf_window() then
    return
  end
  if cfg.open == 'vertical' then
    vim.cmd('botright copen')
    vim.cmd('wincmd L')
    vim.cmd('vertical resize ' .. tonumber(cfg.qf_width))
  else
    vim.cmd('botright copen')
    vim.cmd('resize ' .. tonumber(cfg.qf_height))
  end
  if cfg.equalize then
    vim.cmd('wincmd =')
  end
end

-- Append new lines to quickfix (stdout/stderr)
local function feed(cfg, _, data, _)
  if not data or #data == 0 then return end
  if data[#data] == '' then table.remove(data, #data) end
  if #data == 0 then return end
  vim.fn.setqflist({}, 'a', { lines = data, efm = vim.o.errorformat })
  open_qf_if_needed(cfg)
end

-- Resolve final command (argv list)
local function resolve_cmd(cmd, fallback_makeprg)
  if cmd ~= nil then
    if type(cmd) == 'string' then
      return { vim.o.shell, vim.o.shellcmdflag, cmd }
    elseif type(cmd) == 'table' then
      return cmd
    end
  end
  -- Fallback for build only
  if fallback_makeprg then
    local mp = (vim.o.makeprg ~= '' and vim.o.makeprg) or 'make'
    return { vim.o.shell, vim.o.shellcmdflag, mp }
  end
  return nil
end

-- ---- timers / termination helpers ----
local function clear_timers()
  if timeout_timer then timeout_timer:stop(); timeout_timer:close(); timeout_timer = nil end
  if hardkill_timer then hardkill_timer:stop(); hardkill_timer:close(); hardkill_timer = nil end
end

local function still_running()
  return job_id and job_id > 0
end

local function soft_stop()
  if still_running() then
    pcall(vim.fn.jobstop, job_id) -- polite stop
  end
end

local function hard_kill(cfg)
  if not still_running() then return end
  local uv = vim.loop
  if job_pid and job_pid > 0 then
    pcall(uv.kill, job_pid, tonumber(cfg.hard_kill_signal) or 9)
  end
end

local function schedule_timeout(cfg)
  if (tonumber(cfg.timeout_sec) or 0) <= 0 then return end
  local uv = vim.loop
  timeout_timer = uv.new_timer()
  timeout_timer:start(cfg.timeout_sec * 1000, 0, function()
    if not still_running() then return end
    vim.schedule(function()
      vim.notify(string.format('[projection] timeout after %ds — stopping job...', cfg.timeout_sec), vim.log.levels.WARN)
    end)
    soft_stop()
    -- schedule hard kill after grace
    hardkill_timer = uv.new_timer()
    hardkill_timer:start(tonumber(cfg.kill_grace_ms) or 2000, 0, function()
      if still_running() then
        vim.schedule(function()
          vim.notify('[projection] hard killing job (grace elapsed)', vim.log.levels.ERROR)
        end)
        hard_kill(cfg)
      end
    end)
  end)
end

-- Common runner with header
local function run_with_cmd(cmd_argv, cfg, action_label)
  if not cmd_argv or #cmd_argv == 0 then
    vim.notify('[projection] no command configured', vim.log.levels.WARN)
    return
  end

  -- Prepend a header to the quickfix so the user sees intent and full command.
  local action = action_label or 'Running'
  local header = {}
  if cfg.project_name and tostring(cfg.project_name) ~= '' then
    table.insert(header, string.format('[projection] %s %s', action, cfg.project_name))
  else
    table.insert(header, string.format('[projection] %s project', action))
  end
  table.insert(header, table.concat(cmd_argv or {}, ' '))
  vim.fn.setqflist({}, 'r', { lines = header })
  open_qf_if_needed(cfg)

  -- Now run and stream output, appending to the quickfix
  clear_timers()
  job_id = vim.fn.jobstart(cmd_argv, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(...) feed(cfg, ...) end,
    on_stderr = function(...) feed(cfg, ...) end,
    on_exit = function(_, code)
      clear_timers()
      job_pid = nil
      if cfg.notify then
        if code == 0 then
          vim.notify('[projection] job completed successfully')
        else
          vim.notify('[projection] job failed (exit ' .. code .. ')', vim.log.levels.ERROR)
        end
      end
      if code ~= 0 then
        local qf = vim.fn.getqflist({ size = 0 })
        if qf.size and qf.size > 0 then
          vim.cmd('cfirst')
        end
      end
      job_id = nil
    end,
  })
  job_pid = tonumber(vim.fn.jobpid(job_id)) or nil
  schedule_timeout(cfg)
end

--- Run BUILD with optional one-shot overrides: { cmd = '...', open='vertical', ... }
function M.run_build(opts)
  local cfg = {}
  merge_into(cfg, M.cfg)
  if opts then merge_into(cfg, opts) end
  local argv = resolve_cmd((opts and opts.cmd) or cfg.build_cmd, true) -- build falls back to makeprg
  run_with_cmd(argv, cfg, 'Building')
end

--- Run CLEAN with optional one-shot overrides: { cmd = '...' }
function M.run_clean(opts)
  local cfg = {}
  merge_into(cfg, M.cfg)
  if opts then merge_into(cfg, opts) end
  local argv = resolve_cmd((opts and opts.cmd) or cfg.clean_cmd, false) -- clean has no makeprg fallback
  if not argv then
    vim.notify('[projection] no clean_cmd configured', vim.log.levels.WARN)
    return
  end
  run_with_cmd(argv, cfg, 'Cleaning')
end

--- Back-compat: generic run() uses build path
function M.run(opts)
  return M.run_build(opts)
end

--- Stop the running job (if any)
function M.stop()
  if still_running() then
    clear_timers()
    pcall(vim.fn.jobstop, job_id)
    job_id = nil
    job_pid = nil
    return true
  end
  return false
end

return M
