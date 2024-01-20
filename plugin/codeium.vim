# 检查全局变量，避免重复加载插件
if exists('g:loaded_codeium')
  finish
endif
let g:loaded_codeium = 1

# 定义 Codeium 命令，下面复杂的参数用来自动补全命令的参数
# `!`：表示该命令会覆盖 Vim 内置的命令，如果存在同名的 Vim 命令，则该命令会替换它。
# `-nargs=?`：表示该命令可以接受一个可选的参数，该参数可以通过 `<q-args>` 变量来获取。
# `-complete=customlist,codeium#command#Complete`：表示该命令的参数类型为自定义补全列表 `customlist`，补全列表名为 `codeium#command#Complete`，这里 `codeium#command#Complete` 是一个函数名，用来返回补全列表数据。
# `exe`：表示执行命令，后面跟着的是要执行的具体命令，这里是 `codeium#command#Command(<q-args>)`，表示执行 Codeium 插件相关的命令，并将 `<q-args>` 作为参数传递给该函数。
command! -nargs=? -complete=customlist,codeium#command#Complete Codeium exe codeium#command#Command(<q-args>)

if !codeium#util#HasSupportedVersion()
    finish
endif

# 设置插件的样式
# abort 表示遇到错误时终止执行
function! s:SetStyle() abort
  # 定义 CodeiumSuggestion 高亮组(`hi def`)的样式，
  # 其中 `guifg` 和 `ctermfg` 分别表示在 GUI 模式和终端模式下该高亮组的前景颜色。
  if &t_Co == 256
    # 当终端支持 256 色时，前景色设置为 `#808080`, 表示灰色；
    hi def CodeiumSuggestion guifg=#808080 ctermfg=244
  else
    # 当终端不支持 256 色时，前景色设置为 `8`，表示灰色
    hi def CodeiumSuggestion guifg=#808080 ctermfg=8
  endif
  # 用于将 CodeiumAnnotation 高亮组(`hi def`)与 Normal 高亮组(`Normal` 表示 Vim 内置的高亮组)进行关联(`link`)，
  # 这样 CodeiumAnnotation 就会和 Normal 组具有相同的样式。
  # QA: CodeiumAnnotation 这个的定义在哪里？
  hi def link CodeiumAnnotation Normal
endfunction

# 绑定 TAB 映射
function! s:MapTab() abort
  # 获取用户设置的全局变量进行判断
  if !get(g:, 'codeium_no_map_tab', v:false) && !get(g:, 'codeium_disable_bindings')
    # imap 插入模式
    # QA: <script> 表示在映射过程中执行其它的脚本不会立即生效
    # <silent> 表示所有命令执行时不显示命令行信息，保持安静
    # <nowait> 表示不等待字符输入新行，不用等待更长的输入去匹配映射
    # <expr> 表示将映射右侧“映射表达式”部分作为 vim 脚本解释
    imap <script><silent><nowait><expr> <Tab> codeium#Accept()
  endif
endfunction

augroup codeium
  autocmd!
  # 每当光标进入插入模式、插入模式内的光标移动、补全列表发生变化时，触发 `codeium#DebouncedComplete()` 函数。
  # `codeium#DebouncedComplete()` 函数的作用是完成 Codeium 提示框中的内容 
  autocmd InsertEnter,CursorMovedI,CompleteChanged * call codeium#DebouncedComplete()
  # 每当光标进入一个新的 buffer 时，触发这个命令。
  # 如果光标所在的模式处于插入模式或替换模式，那么就执行 `codeium#DebouncedComplete()` 函数，完成 Codeium 提示框中的内容
  autocmd BufEnter     * if mode() =~# '^[iR]'|call codeium#DebouncedComplete()|endif
  # 当光标从插入模式离开时，执行 `codeium#Clear()` 函数，清除 Codeium 提示框中的内容。
  autocmd InsertLeave  * call codeium#Clear()
  # 当光标从一个 buffer 中离开时，如果光标所在的模式处于插入模式或插入语句完全超出了当前行，那么就执行 `codeium#Clear()` 函数，清除 Codeium 提示框中的内容。
  autocmd BufLeave     * if mode() =~# '^[iR]'|call codeium#Clear()|endif
  # 每当启动 Vim 或更改颜色主题时，执行 `s:SetStyle()` 函数，设置 Codeium 插件的样式
  autocmd ColorScheme,VimEnter * call s:SetStyle()
  " Map tab using vim enter so it occurs after all other sourcing.
  " 当 Vim 启动时，执行 `s:MapTab()` 函数，将 `<Tab>` 键绑定为自动补全 Codeium 提示框中的内容
  autocmd VimEnter             * call s:MapTab()
  " 当 Vim 关闭时，停止 Codeium 服务器，释放占用的资源
  autocmd VimLeave             * call codeium#ServerLeave()
augroup END

# 复杂命令绑定到<Plug>(codeium-dismiss) 上，方便为用户提供自定义键的映射
imap <Plug>(codeium-dismiss)     <Cmd>call codeium#Clear()<CR>
imap <Plug>(codeium-next)     <Cmd>call codeium#CycleCompletions(1)<CR>
imap <Plug>(codeium-next-or-complete)     <Cmd>call codeium#CycleOrComplete()<CR>
imap <Plug>(codeium-previous) <Cmd>call codeium#CycleCompletions(-1)<CR>
imap <Plug>(codeium-complete)  <Cmd>call codeium#Complete()<CR>

if !get(g:, 'codeium_disable_bindings')
  # 如果插入模式下不存在 <C-]> 映射，就创建一个映射
  # 执行 codeium#Clear() 函数后，再返回 <C-]>
  # 因为这是在插入模式中执行 <C-]> 的默认操作，这使得用户能够使用默认的 Vim 行为和 Codeium 编辑器之间进行切换。
  # 因为这个映射使用了脚本引擎，以及当 <script> 标记存在时，将元字符 \<C-]> 转义为字符序列 "\\<C-]>"
  if empty(mapcheck('<C-]>', 'i'))
    imap <silent><script><nowait><expr> <C-]> codeium#Clear() . "\<C-]>"
  endif
  if empty(mapcheck('<M-]>', 'i'))
    imap <M-]> <Plug>(codeium-next-or-complete)
  endif
  if empty(mapcheck('<M-[>', 'i'))
    imap <M-[> <Plug>(codeium-previous)
  endif
  if empty(mapcheck('<M-Bslash>', 'i'))
    imap <M-Bslash> <Plug>(codeium-complete)
  endif
endif

call s:SetStyle()
# 启动一个计时器，0 表示不等待，只有在 vim 等待输入时才会调用回调
# 在用户使用 Codeium 编辑器时启动相关的服务器功能并提高编辑器体验
call timer_start(0, function('codeium#server#Start'))

# 获取当前正在编辑的文件的上一级目录
# 为什么要2个 :h
# `:h` 表示 dirname，即返回 current file path 的 dirname（路径名） 部分。也就是去掉文件名部分，仅返回路径。
# `:h` 后面的又加了一个 `:h`，再次执行 dirname 操作，将当前目录变为父目录。也就是返回 dirname dirname（即路径中去掉最后两部分）。
let s:dir = expand('<sfile>:h:h')
# 判断 codeium.txt 文件是否比 tags 文件更新
if getftime(s:dir . '/doc/codeium.txt') > getftime(s:dir . '/doc/tags')
  # 使用 helptags 重新生成 codeium.txt 文件对应的帮助标签
  # 将生成的标签存储在当前目录的 tags 文件中，这可以帮助用户在使用 Vim 的帮助系统时查找和浏览插件的帮助文档
  silent! execute 'helptags' fnameescape(s:dir . '/doc')
endif

function! CodeiumEnable()  " Enable Codeium if it is disabled
  let g:codeium_enabled = v:true
endfun

command! CodeiumEnable :silent! call CodeiumEnable()

function! CodeiumDisable() " Disable Codeium altogether
  let g:codeium_enabled = v:false
endfun

command! CodeiumDisable :silent! call CodeiumDisable()

function! CodeiumManual() " Disable the automatic triggering of completions
  let g:codeium_manual = v:true
endfun

command! CodeiumManual :silent! call CodeiumManual()

function! CodeiumAuto()  " Enable the automatic triggering of completions
  let g:codeium_manual = v:false
endfun

command! CodeiumAuto :silent! call CodeiumAuto()

# 创建 gui 菜单
:amenu Plugin.Codeium.Enable\ \Codeium\ \(\:CodeiumEnable\) :call CodeiumEnable() <Esc>
:amenu Plugin.Codeium.Disable\ \Codeium\ \(\:CodeiumDisable\) :call CodeiumDisable() <Esc>
:amenu Plugin.Codeium.Manual\ \Codeium\ \AI\ \Autocompletion\ \(\:CodeiumManual\) :call CodeiumManual() <Esc>
:amenu Plugin.Codeium.Automatic\ \Codeium\ \AI\ \Completion\ \(\:CodeiumAuto\) :call CodeiumAuto() <Esc>
