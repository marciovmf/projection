-- lua/projection/init.lua
-- projection.nvim: stream build/clean commands into the quickfix list in real time.
-- Adds project-aware config, keymaps, timeouts, header lines, and personality messages.

local M = {}

-- Default configuration
M.cfg = {
  build_cmd = nil,
  clean_cmd = nil,
  open = 'horizontal',
  qf_height = 12,
  qf_width = 50,
  equalize = false,
  notify = true,
  timeout_sec = 0,
  kill_grace_ms = 2000,
  hard_kill_signal = 9,
  project_name = nil,
  build_key = nil,
  clean_key = nil,

  -- Fun / Personality
  success_icon = nil,
  fail_icon = nil,
  success_phrases = {},
  failure_phrases = {},
}

local job_id = nil
local job_pid = nil
local timeout_timer = nil
local hardkill_timer = nil

M._orig_titlestring = nil
M._title_active = false
M._last_build_key = nil
M._last_clean_key = nil

----------------------------------------------------------------------
-- Private RNG (LCG) so other plugins can't mess with it
----------------------------------------------------------------------

local RAND_A, RAND_C, RAND_M = 1103515245, 12345, 2 ^ 31
M._rand_state =
  (vim.loop and vim.loop.hrtime and (vim.loop.hrtime() % RAND_M)) or (os.time() % RAND_M)

local function prand(n)
  M._rand_state = (RAND_A * M._rand_state + RAND_C) % RAND_M
  if n then
    return (M._rand_state % n) + 1
  end
  return M._rand_state
end

M._last_success_idx = nil
M._last_failure_idx = nil

----------------------------------------------------------------------
-- Utility helpers
----------------------------------------------------------------------

local function coerce(v)
  if v == 'true' or v == true then
    return true
  end
  if v == 'false' or v == false then
    return false
  end
  if type(v) == 'string' then
    local n = tonumber(v)
    if n ~= nil then
      return n
    end
  end
  return v
end

local function merge_into(dst, src)
  if type(src) ~= 'table' then
    return dst
  end
  for k, v in pairs(src) do
    dst[k] = coerce(v)
  end
  return dst
end

function M.setup(opts)
  if opts then
    merge_into(M.cfg, opts)
  end
  M._apply_project_name()
  M._apply_keymaps()
end

function M.apply_global_var()
  local gv = vim.g.projection
  if type(gv) == 'table' then
    M.setup(gv)
  end
end

----------------------------------------------------------------------
-- Project config loader
----------------------------------------------------------------------

local function find_upwards(names)
  local uv = vim.loop
  local cwd = uv.cwd() or '.'
  local sep = package.config:sub(1, 1)
  local function join(a, b)
    return a .. sep .. b
  end

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
    if not parent or parent == '' then
      break
    end
    dir = parent
  end
  return nil
end

function M.load_project_config()
  local path = find_upwards({ 'project.lua', '.make-live.lua', '.nvim/make-live.lua' })
  if not path then
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
  M._apply_project_name()
  M._apply_keymaps()
  return true
end

----------------------------------------------------------------------
-- Project name, keymaps, quickfix management
----------------------------------------------------------------------

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
  local name = M.cfg.project_name
  if name and tostring(name) ~= '' then
    if not M._title_active then
      M._orig_titlestring = vim.o.titlestring ~= '' and vim.o.titlestring or '%f - nvim'
    end
    vim.o.title = true
    vim.o.titlestring =
      string.format('[%s] %s', tostring(name), M._orig_titlestring or '%f - nvim')
    M._title_active = true
  else
    M._clear_project_name_effects()
  end
end

function M._clear_keymaps()
  if M._last_build_key then
    pcall(vim.keymap.del, 'n', M._last_build_key)
  end
  if M._last_clean_key then
    pcall(vim.keymap.del, 'n', M._last_clean_key)
  end
  M._last_build_key = nil
  M._last_clean_key = nil
end

function M._apply_keymaps()
  M._clear_keymaps()
  if M.cfg.build_key and tostring(M.cfg.build_key) ~= '' then
    vim.keymap.set('n', M.cfg.build_key, function()
      M.run_build()
    end, { desc = 'projection: build' })
    M._last_build_key = M.cfg.build_key
  end
  if M.cfg.clean_key and tostring(M.cfg.clean_key) ~= '' then
    vim.keymap.set('n', M.cfg.clean_key, function()
      M.run_clean()
    end, { desc = 'projection: clean' })
    M._last_clean_key = M.cfg.clean_key
  end
end

local function has_qf_window()
  for _, win in ipairs(vim.fn.getwininfo()) do
    if win.quickfix == 1 then
      return true
    end
  end
  return false
end

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

local function feed(cfg, _, data, _)
  if not data or #data == 0 then
    return
  end
  if data[#data] == '' then
    table.remove(data, #data)
  end
  if #data == 0 then
    return
  end
  vim.fn.setqflist({}, 'a', { lines = data, efm = vim.o.errorformat })
  open_qf_if_needed(cfg)
end

----------------------------------------------------------------------
-- Process + timeout management
----------------------------------------------------------------------

local function resolve_cmd(cmd, fallback_makeprg)
  if cmd ~= nil then
    if type(cmd) == 'string' then
      return { vim.o.shell, vim.o.shellcmdflag, cmd }
    elseif type(cmd) == 'table' then
      return cmd
    end
  end
  if fallback_makeprg then
    local mp = (vim.o.makeprg ~= '' and vim.o.makeprg) or 'make'
    return { vim.o.shell, vim.o.shellcmdflag, mp }
  end
  return nil
end

local function clear_timers()
  if timeout_timer then
    timeout_timer:stop()
    timeout_timer:close()
    timeout_timer = nil
  end
  if hardkill_timer then
    hardkill_timer:stop()
    hardkill_timer:close()
    hardkill_timer = nil
  end
end

local function still_running()
  return job_id and job_id > 0
end

local function soft_stop()
  if still_running() then
    pcall(vim.fn.jobstop, job_id)
  end
end

local function hard_kill(cfg)
  if not still_running() then
    return
  end
  local uv = vim.loop
  if job_pid and job_pid > 0 then
    pcall(uv.kill, job_pid, tonumber(cfg.hard_kill_signal) or 9)
  end
end

local function schedule_timeout(cfg)
  if (tonumber(cfg.timeout_sec) or 0) <= 0 then
    return
  end
  local uv = vim.loop
  timeout_timer = uv.new_timer()
  timeout_timer:start(cfg.timeout_sec * 1000, 0, function()
    if not still_running() then
      return
    end
    vim.schedule(function()
      vim.notify(
        string.format('[projection] timeout after %ds — stopping job...', cfg.timeout_sec),
        vim.log.levels.WARN
      )
    end)
    soft_stop()
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

----------------------------------------------------------------------
-- Personality system
----------------------------------------------------------------------

local function pick_phrase(list, last_idx)
  if type(list) ~= 'table' or #list == 0 then
    return nil, last_idx
  end
  local idx = prand(#list)
  if #list > 1 then
    local tries = 3
    while idx == last_idx and tries > 0 do
      idx = prand(#list)
      tries = tries - 1
    end
  end
  return list[idx], idx
end

local function emit_personality(cfg, ok)
  local icon = ok and cfg.success_icon or cfg.fail_icon
  local phrase, new_idx
  if ok then
    phrase, M._last_success_idx = pick_phrase(cfg.success_phrases, M._last_success_idx)
  else
    phrase, M._last_failure_idx = pick_phrase(cfg.failure_phrases, M._last_failure_idx)
  end
  if not icon and not phrase then
    return
  end

  local line = (icon and (tostring(icon) .. ' ') or '') .. (phrase or '')
  if line == '' then
    return
  end

  -- Visual spacing before the punchline
  vim.fn.setqflist({}, 'a', { lines = { '', '', line, '' } })

  if cfg.notify then
    vim.notify(line, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end
end

----------------------------------------------------------------------
-- Main runner
----------------------------------------------------------------------

local function run_with_cmd(cmd_argv, cfg, action_label)
  if not cmd_argv or #cmd_argv == 0 then
    vim.notify('[projection] no command configured', vim.log.levels.WARN)
    return
  end

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

  clear_timers()
  job_id = vim.fn.jobstart(cmd_argv, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(...)
      feed(cfg, ...)
    end,
    on_stderr = function(...)
      feed(cfg, ...)
    end,
    on_exit = function(_, code)
      clear_timers()
      job_pid = nil
      local ok = (code == 0)
      if cfg.notify then
        if ok then
          vim.notify('[projection] job completed successfully')
        else
          vim.notify('[projection] job failed (exit ' .. code .. ')', vim.log.levels.ERROR)
        end
      end

      if not ok then
        local qf = vim.fn.getqflist({ size = 0 })
        if qf.size and qf.size > 0 then
          vim.cmd('cfirst')
        end
      end

      emit_personality(cfg, ok)

      -- Scroll to bottom of quickfix for dramatic effect
      if has_qf_window() then
        vim.schedule(function()
          local qfwin = vim.fn.getqflist({ winid = 0 }).winid
          if qfwin and qfwin > 0 then
            vim.api.nvim_win_call(qfwin, function()
              vim.cmd('normal! G')
            end)
          end
        end)
      end

      job_id = nil
    end,
  })
  job_pid = tonumber(vim.fn.jobpid(job_id)) or nil
  schedule_timeout(cfg)
end

----------------------------------------------------------------------
-- Public commands
----------------------------------------------------------------------

function M.run_build(opts)
  local cfg = {}
  merge_into(cfg, M.cfg)
  if opts then
    merge_into(cfg, opts)
  end
  local argv = resolve_cmd((opts and opts.cmd) or cfg.build_cmd, true)
  run_with_cmd(argv, cfg, 'Building')
end

function M.run_clean(opts)
  local cfg = {}
  merge_into(cfg, M.cfg)
  if opts then
    merge_into(cfg, opts)
  end
  local argv = resolve_cmd((opts and opts.cmd) or cfg.clean_cmd, false)
  if not argv then
    vim.notify('[projection] no clean_cmd configured', vim.log.levels.WARN)
    return
  end
  run_with_cmd(argv, cfg, 'Cleaning')
end

function M.run(opts)
  return M.run_build(opts)
end

function M.stop()
  if job_id and job_id > 0 then
    clear_timers()
    pcall(vim.fn.jobstop, job_id)
    job_id = nil
    job_pid = nil
    return true
  end
  return false
end

return M
