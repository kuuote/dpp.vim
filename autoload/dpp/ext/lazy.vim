function dpp#ext#lazy#_source(plugins) abort
  let plugins = dpp#util#_convert2list(a:plugins)
  if plugins->empty()
    return []
  endif

  if plugins[0]->type() != v:t_dict
    let plugins = dpp#util#_convert2list(a:plugins)
          \ ->map({ _, val -> g:dpp#_plugins->get(val, {}) })
  endif

  let rtps = dpp#util#_split_rtp(&runtimepath)
  const index = rtps->index(dpp#util#_get_runtime_path())
  if index < 0
    return []
  endif

  let sourced = []
  for plugin in plugins
        \ ->filter({ _, val ->
        \  !(val->empty()) && !val.sourced && val.rtp !=# ''
        \  && (!(v:val->has_key('if')) || v:val.if->eval())
        \  && v:val.path->isdirectory()
        \ })
    call s:source_plugin(rtps, index, plugin, sourced)
  endfor

  const filetype_before = 'autocmd FileType'->execute()
  let &runtimepath = dpp#util#_join_rtp(rtps, &runtimepath, '')

  call dpp#util#_call_hook('source', sourced)

  " Reload script files.
  for plugin in sourced
    for directory in ['ftdetect', 'after/ftdetect', 'plugin', 'after/plugin']
          \ ->filter({ _, val -> (plugin.rtp .. '/' .. val)->isdirectory() })
          \ ->map({ _, val -> plugin.rtp .. '/' .. val })
      if directory =~# 'ftdetect'
        if !(plugin->get('merge_ftdetect'))
          execute 'augroup filetypedetect'
        endif
      endif
      let files = (directory .. '/**/*.vim')->glob(v:true, v:true)
      if has('nvim')
        let files += (directory .. '/**/*.lua')->glob(v:true, v:true)
      endif
      for file in files
        execute 'source' file->fnameescape()
      endfor
      if directory =~# 'ftdetect'
        execute 'augroup END'
      endif
    endfor

    if !has('vim_starting')
      const augroup = plugin->get('augroup',
            \ dpp#util#_get_normalized_name(plugin))
      let events = ['VimEnter', 'BufRead', 'BufEnter',
            \ 'BufWinEnter', 'WinEnter']
      if has('gui_running') && &term ==# 'builtin_gui'
        call add(events, 'GUIEnter')
      endif
      for event in events
        if ('#' .. augroup .. '#' .. event)->exists()
          silent execute 'doautocmd' augroup event
        endif
      endfor

      " Register for lazy loaded denops plugin
      if (plugin.rtp .. '/denops')->isdirectory()
        for name in 'denops/*/main.ts'
              \ ->globpath(plugin.rtp, v:true, v:true)
              \ ->map({ _, val -> val->fnamemodify(':h:t')})
              \ ->filter({ _, val -> !denops#plugin#is_loaded(val) })

          if denops#server#status() ==# 'running'
            " NOTE: denops#plugin#register() may be failed
            silent! call denops#plugin#register(name, #{ mode: 'skip' })
          endif

          if plugin->get('denops_wait', v:true)
            call denops#plugin#wait(name)
            redraw
          endif
        endfor
      endif
    endif
  endfor

  const filetype_after = 'autocmd FileType'->execute()

  const is_reset = s:is_reset_ftplugin(sourced)
  if is_reset
    " NOTE: filetype plugins must be reset to load new ftplugins
    call s:reset_ftplugin()
  endif

  if (is_reset || filetype_before !=# filetype_after) && &l:filetype !=# ''
    " Recall FileType autocmd
    let &l:filetype = &l:filetype
  endif

  if !has('vim_starting')
    call dpp#util#_call_hook('post_source', sourced)
  endif

  return sourced
endfunction

function dpp#ext#lazy#_on_default_event(event) abort
  let lazy_plugins = dpp#util#_get_lazy_plugins()
  let plugins = []

  let path = '<afile>'->expand()
  " For ":edit ~".
  if path->fnamemodify(':t') ==# '~'
    let path = '~'
  endif
  let path = dpp#util#_expand(path)

  for filetype in &l:filetype->split('\.')
    let plugins += lazy_plugins->copy()
          \ ->filter({ _, val -> val->get('on_ft', [])
          \ ->index(filetype) >= 0 })
  endfor

  let plugins += lazy_plugins->copy()
        \ ->filter({ _, val -> !(val->get('on_path', [])->copy()
        \ ->filter({ _, val -> path =~? val })->empty()) })
  let plugins += lazy_plugins->copy()
        \ ->filter({ _, val ->
        \   !(val->has_key('on_event')) && val->has_key('on_if')
        \   && val.on_if->eval() })

  call s:source_events(a:event, plugins)
endfunction
function dpp#ext#lazy#_on_event(event, plugins) abort
  let lazy_plugins = dpp#util#_get_plugins(a:plugins)
        \ ->filter({ _, val -> !val.sourced })
  if lazy_plugins->empty()
    execute 'autocmd! dpp-events' a:event
    return
  endif

  let plugins = lazy_plugins->copy()
        \ ->filter({ _, val ->
        \          !(val->has_key('on_if')) || val.on_if->eval() })
  call s:source_events(a:event, plugins)
endfunction
function s:source_events(event, plugins) abort
  if empty(a:plugins)
    return
  endif

  const prev_autocmd = ('autocmd ' .. a:event)->execute()

  call dpp#ext#lazy#_source(a:plugins)

  const new_autocmd = ('autocmd ' .. a:event)->execute()

  if a:event ==# 'InsertCharPre'
    " Queue this key again
    call feedkeys(v:char)
    let v:char = ''
  else
    if '#BufReadCmd'->exists() && a:event ==# 'BufNew'
      " For BufReadCmd plugins
      silent doautocmd <nomodeline> BufReadCmd
    endif
    if ('#' .. a:event)->exists() && prev_autocmd !=# new_autocmd
      execute 'doautocmd <nomodeline>' a:event
    elseif ('#User#' .. a:event)->exists()
      execute 'doautocmd <nomodeline> User' a:event
    endif
  endif
endfunction

function dpp#ext#lazy#_on_func(name) abort
  const function_prefix = a:name->substitute('[^#]*$', '', '')
  if function_prefix =~# '^dpp#'
        \ || (function_prefix =~# '^vital#' &&
        \     function_prefix !~# '^vital#vital#')
    return
  endif

  call dpp#ext#lazy#_source(dpp#util#_get_lazy_plugins()
        \ ->filter({ _, val ->
        \          function_prefix->stridx(
        \             dpp#util#_get_normalized_name(val).'#') == 0
        \          || val->get('on_func', [])->index(a:name) >= 0 }))
endfunction

function dpp#ext#lazy#_on_lua(name) abort
  if g:dpp#_called_lua->has_key(a:name)
    return
  endif

  " Only use the root of module name.
  const mod_root = a:name->matchstr('^[^./]\+')

  " Prevent infinite loop
  let g:dpp#_called_lua[a:name] = v:true

  call dpp#ext#lazy#_source(dpp#util#_get_lazy_plugins()
        \ ->filter({ _, val ->
        \          val->get('on_lua', [])->index(mod_root) >= 0 }))
endfunction

function dpp#ext#lazy#_on_pre_cmd(name) abort
  call dpp#ext#lazy#_source(
        \ dpp#util#_get_lazy_plugins()
        \  ->filter({ _, val -> copy(val->get('on_cmd', []))
        \  ->map({ _, val2 -> tolower(val2) })
        \  ->index(a:name) >= 0
        \  || a:name->tolower()
        \     ->stridx(dpp#util#_get_normalized_name(val)->tolower()
        \     ->substitute('[_-]', '', 'g')) == 0 }))
endfunction

function dpp#ext#lazy#_on_cmd(command, name, args, bang, line1, line2) abort
  call dpp#source(a:name)

  if (':' .. a:command)->exists() != 2
    call dpp#util#_error(printf('command %s is not found.', a:command))
    return
  endif

  const range = (a:line1 == a:line2) ? '' :
        \ (a:line1 == "'<"->line() && a:line2 == "'>"->line()) ?
        \ "'<,'>" : a:line1 .. ',' .. a:line2

  try
    execute range.a:command.a:bang a:args
  catch /^Vim\%((\a\+)\)\=:E481/
    " E481: No range allowed
    execute a:command.a:bang a:args
  endtry
endfunction

function dpp#ext#lazy#_on_map(mapping, name, mode) abort
  const cnt = v:count > 0 ? v:count : ''

  const input = s:get_input()

  const sourced = dpp#source(a:name)
  if sourced->empty()
    " Prevent infinite loop
    silent! execute a:mode.'unmap' a:mapping
  endif

  if a:mode ==# 'v' || a:mode ==# 'x'
    call feedkeys('gv', 'n')
  elseif a:mode ==# 'o' && v:operator !=# 'c'
    const save_operator = v:operator
    call feedkeys("\<Esc>", 'in')

    " Cancel waiting operator mode.
    call feedkeys(save_operator, 'imx')
  endif

  call feedkeys(cnt, 'n')

  if a:mode ==# 'o' && v:operator ==# 'c'
    " NOTE: This is the dirty hack.
    execute s:mapargrec(a:mapping .. input, a:mode)->matchstr(
          \ ':<C-u>\zs.*\ze<CR>')
  else
    let mapping = a:mapping
    while mapping =~# '<[[:alnum:]_-]\+>'
      let mapping = mapping->substitute('\c<Leader>',
            \ g:->get('mapleader', '\'), 'g')
      let mapping = mapping->substitute('\c<LocalLeader>',
            \ g:->get('maplocalleader', '\'), 'g')
      let ctrl = mapping->matchstr('<\zs[[:alnum:]_-]\+\ze>')
      execute 'let mapping = mapping->substitute(
            \ "<' .. ctrl .. '>", "\<' .. ctrl .. '>", "")'
    endwhile

    if a:mode ==# 't'
      call feedkeys('i', 'n')
    endif
    call feedkeys(mapping .. input, 'm')
  endif

  return ''
endfunction

function dpp#ext#lazy#_dummy_complete(arglead, cmdline, cursorpos) abort
  const command = a:cmdline->matchstr('\h\w*')
  if (':' .. command)->exists() == 2
    " Remove the dummy command.
    silent! execute 'delcommand' command
  endif

  " Load plugins
  call dpp#ext#lazy#_on_pre_cmd(tolower(command))

  return a:arglead
endfunction

function s:source_plugin(rtps, index, plugin, sourced) abort
  if a:plugin.sourced || a:sourced->index(a:plugin) >= 0
    \ || (a:plugin->has_key('if') && !(a:plugin.if->eval()))
    return
  endif

  call insert(a:sourced, a:plugin)

  let index = a:index

  " NOTE: on_source must sourced after depends
  for on_source in dpp#util#_get_lazy_plugins()
        \ ->filter({ _, val ->
        \          val->get('on_source', []) ->index(a:plugin.name) >= 0
        \ })
    if s:source_plugin(a:rtps, index, on_source, a:sourced)
      let index += 1
    endif
  endfor

  " Load dependencies
  for name in a:plugin->get('depends', [])
    if !(g:dpp#_plugins->has_key(name))
      call dpp#util#_error(printf(
            \ 'Plugin "%s" depends "%s" but it is not found.',
            \ a:plugin.name, name))
      continue
    endif

    if !a:plugin.lazy && g:dpp#_plugins[name].lazy
      call dpp#util#_error(printf(
            \ 'Not lazy plugin "%s" depends lazy "%s" plugin.',
            \ a:plugin.name, name))
      continue
    endif

    if s:source_plugin(a:rtps, index, g:dpp#_plugins[name], a:sourced)
      let index += 1
    endif
  endfor

  let a:plugin.sourced = 1

  if a:plugin->has_key('dummy_commands')
    for command in a:plugin.dummy_commands
      silent! execute 'delcommand' command[0]
    endfor
    let a:plugin.dummy_commands = []
  endif

  if a:plugin->has_key('dummy_mappings')
    for map in a:plugin.dummy_mappings
      silent! execute map[0].'unmap' map[1]
    endfor
    let a:plugin.dummy_mappings = []
  endif

  if !a:plugin.merged || a:plugin->get('local', 0)
    call insert(a:rtps, a:plugin.rtp, index)
    if (a:plugin.rtp .. '/after')->isdirectory()
      call dpp#util#_add_after(a:rtps, a:plugin.rtp .. '/after')
    endif
  endif

  if g:->get('dpp#lazy_rplugins', v:false) && !g:dpp#_loaded_rplugins
        \ && (a:plugin.rtp .. '/rplugin')->isdirectory()
    " Enable remote plugin
    unlet! g:loaded_remote_plugins

    runtime! plugin/rplugin.vim

    let g:dpp#_loaded_rplugins = v:true
  endif
endfunction
function s:reset_ftplugin() abort
  const filetype_state = 'filetype'->execute()

  if 'b:did_indent'->exists() || 'b:did_ftplugin'->exists()
    filetype plugin indent off
  endif

  if filetype_state =~# 'plugin:ON'
    silent! filetype plugin on
  endif

  if filetype_state =~# 'indent:ON'
    silent! filetype indent on
  endif
endfunction
function s:get_input() abort
  let input = ''
  const termstr = '<M-_>'

  call feedkeys(termstr, 'n')

  while 1
    let char = getchar()
    let input ..= (char->type() == v:t_number) ? char->nr2char() : char

    let idx = input->stridx(termstr)
    if idx >= 1
      let input = input[: idx - 1]
      break
    elseif idx == 0
      let input = ''
      break
    endif
  endwhile

  return input
endfunction

function s:is_reset_ftplugin(plugins) abort
  if &l:filetype ==# ''
    return 0
  endif

  for plugin in a:plugins
    let ftplugin = plugin.rtp .. '/ftplugin/' .. &l:filetype
    let after = plugin.rtp .. '/after/ftplugin/' .. &l:filetype
    let check_ftplugin = !(['ftplugin', 'indent',
          \ 'after/ftplugin', 'after/indent',]
          \ ->filter({ _, val -> printf('%s/%s/%s.vim',
          \          plugin.rtp, val, &l:filetype)->filereadable()
          \          || printf('%s/%s/%s.lua',
          \          plugin.rtp, val, &l:filetype)->filereadable()
        \ })->empty())
    if check_ftplugin
          \ || ftplugin->isdirectory() || after->isdirectory()
          \ || (ftplugin .. '_*.vim')->glob(v:true) !=# ''
          \ || (after .. '_*.vim')->glob(v:true) !=# ''
          \ || (ftplugin .. '_*.lua')->glob(v:true) !=# ''
          \ || (after .. '_*.lua')->glob(v:true) !=# ''
      return 1
    endif
  endfor
  return 0
endfunction
function s:mapargrec(map, mode) abort
  let arg = a:map->maparg(a:mode)
  while arg->maparg(a:mode) !=# ''
    let arg = arg->maparg(a:mode)
  endwhile
  return arg
endfunction

function dpp#ext#lazy#_generate_dummy_commands(plugin) abort
  let dummy_commands = []
  for name in dpp#util#_convert2list(a:plugin->get('on_cmd', []))
    " Define dummy commands.
    let raw_cmd = 'command '
          \ .. '-complete=custom,dpp#autoload#_dummy_complete'
          \ .. ' -bang -bar -range -nargs=* '. name
          \ .. printf(" call dpp#autoload#_on_cmd(%s, %s, <q-args>,
          \  '<bang>'->expand(), '<line1>'->expand(), '<line2>'->expand())",
          \   name->string(), a:plugin.name->string())

    call add(dummy_commands, raw_cmd)
  endfor
  return dummy_commands
endfunction
function dpp#ext#lazy#_generate_dummy_mappings(plugin) abort
  let dummy_mappings = []
  const normalized_name = dpp#util#_get_normalized_name(a:plugin)
  const on_map = a:plugin->get('on_map', [])
  let items = on_map->type() == v:t_dict ?
        \ on_map->items()->map({ _, val -> [val[0]->split('\zs'),
        \       dpp#util#_convert2list(val[1])]}) :
        \ on_map->copy()->map({ _, val -> type(val) == v:t_list ?
        \       [val[0]->split('\zs'), val[1:]] :
        \       [['n', 'x', 'o'], [val]]
        \  })
  for [modes, mappings] in items
    if mappings ==# ['<Plug>']
      " Use plugin name.
      let mappings = ['<Plug>(' .. normalized_name]
      if normalized_name->stridx('-') >= 0
        " The plugin mappings may use "_" instead of "-".
        call add(mappings, '<Plug>('
              \ .. normalized_name->substitute('-', '_', 'g'))
      endif
    endif

    for mapping in mappings
      " Define dummy mappings.
      let prefix = printf('dpp#autoload#_on_map(%s, %s,',
            \ mapping->substitute('<', '<lt>', 'g')->string(),
            \ a:plugin.name->string())
      for mode in modes
        let escape = has('nvim') ? "\<C-\>\<C-n>" : "\<C-l>N"
        let raw_map = mode.'noremap <unique><silent> '.mapping
              \ .. (mode ==# 'c' ? " \<C-r>=" :
              \     mode ==# 'i' ? " \<C-o>:call " :
              \     mode ==# 't' ? " " .. escape .. ":call " :
              \     " :\<C-u>call ")
              \ .. prefix .. mode->string() .. ')<CR>'
        call add(dummy_mappings, raw_map)
      endfor
    endfor
  endfor

  return dummy_mappings
endfunction
function dpp#ext#lazy#_generate_on_lua(plugin) abort
  return dpp#util#_convert2list(a:plugin.on_lua)
        \ ->map({ _, val -> val->matchstr('^[^./]\+') })
        \ ->map({ _, mod -> printf("let g:dpp#_on_lua_plugins[%s] = v:true",
        \                          string(mod) )})
endfunction
