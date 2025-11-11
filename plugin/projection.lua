-- plugin/projection.lua
-- Registers user commands and auto-loaders. Messages are in ENGLISH.

-- Apply global configuration from g:projection if present
pcall(function() require('projection').apply_global_var() end)

-- Auto-load per-project configuration on startup and when directory changes
vim.api.nvim_create_autocmd({ 'VimEnter', 'DirChanged' }, {
  group = vim.api.nvim_create_augroup('ProjectionProjectConfig', { clear = true }),
  callback = function()
    pcall(function() require('projection').load_project_config() end)
  end,
})

-- :Projection / :ProjectionBuild [args...]
vim.api.nvim_create_user_command('Projection', function(opts)
  require('projection').run_build({ cmd = opts.args ~= '' and opts.args or nil })
end, {
  nargs = '*',
  complete = 'shellcmd',
  desc = 'Stream build command into quickfix in real time',
})
vim.api.nvim_create_user_command('ProjectionBuild', function(opts)
  require('projection').run_build({ cmd = opts.args ~= '' and opts.args or nil })
end, {
  nargs = '*',
  complete = 'shellcmd',
  desc = 'Stream build command into quickfix in real time',
})

-- :ProjectionClean [args...]
vim.api.nvim_create_user_command('ProjectionClean', function(opts)
  require('projection').run_clean({ cmd = opts.args ~= '' and opts.args or nil })
end, {
  nargs = '*',
  complete = 'shellcmd',
  desc = 'Stream clean command into quickfix in real time',
})

-- :ProjectionStop
vim.api.nvim_create_user_command('ProjectionStop', function()
  if require('projection').stop() then
    vim.notify('[projection] job stopped')
  else
    vim.notify('[projection] no running job', vim.log.levels.WARN)
  end
end, { desc = 'Stop the running job' })

-- :ProjectionConfig key=val [key=val ...]
-- Supports build_key and clean_key for keymaps (e.g., "<F9>", "<C-b>")
vim.api.nvim_create_user_command('ProjectionConfig', function(opts)
  local kv = {}
  for token in string.gmatch(opts.args or '', '%S+') do
    local k, v = token:match('([^=]+)=(.+)')
    if k and v then kv[k] = v end
  end
  if next(kv) then
    local mod = require('projection')
    mod.setup(kv)
    vim.notify('[projection] config updated')
  else
    vim.notify('[projection] usage: :ProjectionConfig key=val [key=val...]', vim.log.levels.WARN)
  end
end, {
  nargs = '*',
  desc = 'Update Projection config at runtime (key=val pairs)',
})

-- Keep a simple Vimscript-compatible status fragment updated
vim.g.projection_status = (pcall(function() return require('projection').status() end) and require('projection').status()) or ''
vim.api.nvim_create_autocmd({ 'BufEnter', 'DirChanged', 'VimEnter' }, {
  group = vim.api.nvim_create_augroup('ProjectionStatusline', { clear = true }),
  callback = function()
    local ok, mod = pcall(require, 'projection')
    if ok and mod and type(mod.status) == 'function' then
      vim.g.projection_status = mod.status()
    end
  end
})
