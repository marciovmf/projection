# projection.nvim

Stream your **build** and **clean** commands into Neovim’s quickfix **in real time**.
Understands `errorformat`, opens quickfix horizontally/vertically, avoids duplicate
windows, can equalize sizes, auto-loads `project.lua` per project, has a timeout
failsafe, and supports **per-project keymaps** for build/clean.

https://github.com/yourname/projection.nvim

## Features

- Live streaming of stdout/stderr to the quickfix list
- Separate `build_cmd` and `clean_cmd`
- Per-project keymaps: `build_key`, `clean_key` (e.g. `<F9>`, `<C-b>`)
- Honors `makeprg` and `errorformat` (build falls back to `makeprg`/`make`)
- Quickfix auto-open: horizontal/vertical/never
- No duplicate quickfix windows
- Optional `Ctrl-W =` equalization after opening
- Global, per-project (`project.lua`), and runtime configuration
- Timeout failsafe with soft-stop and hard-kill
- `project_name` shown in title bar and available for statusline
- Commands: `:Projection`, `:ProjectionBuild`, `:ProjectionClean`, `:ProjectionStop`, `:ProjectionConfig`

## Install (vim-plug)

```vim
Plug 'yourname/projection.nvim'
```

## project.lua (auto-loaded)

Put a `project.lua` at your project root:

```lua
return {
  project_name = 'AwesomeApp',
  build_cmd = { 'ninja', '-v' },          -- argv (no shell)
  clean_cmd = { 'ninja', '-t', 'clean' }, -- argv (no shell)
  build_key = '<F9>',
  clean_key = '<S-F9>',
  open = 'horizontal',
  qf_height = 18,
  equalize = true,
  timeout_sec = 45,
}
```

## Global config (no init.lua edits required)

```vim
let g:projection = {
\ 'project_name': 'MyProject',
\ 'build_cmd': ['make', '-j8'],
\ 'clean_cmd': ['make', 'clean'],
\ 'build_key': '<F9>',
\ 'clean_key': '<S-F9>',
\ 'open': 'vertical',
\ 'qf_width': 60,
\ 'equalize': v:true,
\ 'notify': v:true,
\ 'timeout_sec': 30,
\}
```

## Commands

- `:Projection` / `:ProjectionBuild [cmd ...]` – run build and stream into quickfix
- `:ProjectionClean [cmd ...]` – run clean and stream into quickfix
- `:ProjectionStop` – stop the current job
- `:ProjectionConfig key=val [key=val ...]` – update config at runtime
  - supports `build_cmd`, `clean_cmd`, `build_key`, `clean_key`, and others

## API (Lua)

```lua
local ml = require('projection')
ml.setup{ build_cmd = 'make -j8', clean_cmd = 'make clean', build_key = '<F9>' }
ml.run_build()              -- start build
ml.run_clean()              -- start clean
ml.stop()                   -- stop job
ml.status()                 -- -> "[ProjectName]" or ""
```

## Options (defaults)

```lua
require('projection').setup{
  build_cmd = nil,          -- string | table | nil (fallback to &makeprg or "make")
  clean_cmd = nil,          -- string | table | nil (no fallback)
  open = 'horizontal',      -- 'horizontal' | 'vertical' | 'never'
  qf_height = 12,
  qf_width  = 50,
  equalize = false,         -- apply Ctrl-W = after opening
  notify = true,
  timeout_sec = 0,          -- 0 disables timeout
  kill_grace_ms = 2000,
  hard_kill_signal = 9,
  project_name = nil,       -- visible in title bar and statusline helper
  build_key = nil,          -- e.g., '<F9>'
  clean_key = nil,          -- e.g., '<S-F9>'
}
```

## License

MIT © Your Name
