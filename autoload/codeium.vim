# CodeiumSuggestion 是文本属性的属性名
let s:hlgroup = 'CodeiumSuggestion'
let s:request_nonce = 0
let s:using_codeium_status = 0

# 设置缓冲区中的文本可附属文本属性，主要用途是文本的高亮
if !has('nvim')
  # 文本属性 CodeiumSuggestion 不存在则新增，highlight 高亮组名刚好是 CodeiumSuggestion
  if empty(prop_type_get(s:hlgroup))
    call prop_type_add(s:hlgroup, {'highlight': s:hlgroup})
  endif
endif

let s:default_codeium_enabled = {
      \ 'help': 0,
      \ 'gitcommit': 0,
      \ 'gitrebase': 0,
      \ '.': 0}

# 根据开关和文件类型，判断是否开启 codeium
function! codeium#Enabled() abort
  # 检查全局变量和 buffer 变量 codeium_enabled，只要一个为 false，就返回 false
  # 为什么要两个变量
  # 确保Codeium插件在本地或全局已经被启用
  if !get(g:, 'codeium_enabled', v:true) || !get(b:, 'codeium_enabled', v:true)
    return v:false
  endif

  let codeium_filetypes = s:default_codeium_enabled
  # 把全局变量 codeium_filetypes 附加到变量 codeium_filetypes 后面
  call extend(codeium_filetypes, get(g:, 'codeium_filetypes', {}))
  # &filetype 是 vim 的一个特殊变量，包含当前的文件类型
  if !get(codeium_filetypes, &filetype, 1)
    return v:false
  endif

  return v:true
endfunction

# 返回 s:completion_text 的值，并将变量删除
function! codeium#CompletionText() abort
  try
    return remove(s:, 'completion_text')
  catch
    return ''
  endtry
endfunction

function! codeium#Accept() abort
  # 如果 codeium_tab_fallback 全局变量不存在则使用默认值赋值到 default 变量
  # pumvisible() 为真，则使用 Ctrl+N 键，否则使用 tab 键盘
  # 如果弹出菜单可见，pumvisible 为真
  let default = get(g:, 'codeium_tab_fallback', pumvisible() ? "\<C-N>" : "\t")

  # 判断当前模式不是插入模式或替换模式，则为 true
  # mode() 返回当前 vim 中的模式，比如普通模式
  # !~# 是一个正式表达式符号，表示匹配失败
  # ^[iR] 表示以 i 或 R 开头
  if mode() !~# '^[iR]' || !exists('b:_codeium_completions')
    return default
  endif

  # 获取当前选中的补全项内容
  let current_completion = s:GetCurrentCompletionItem()
  # 如果当前没有补全内容，则返回默认的按键
  if current_completion is v:null
    return default
  endif

  let range = current_completion.range
  let suffix = get(current_completion, 'suffix', {})
  let suffix_text = get(suffix, 'text', '')
  let delta = get(suffix, 'deltaCursorOffset', 0)
  let start_offset = get(range, 'startOffset', 0)
  let end_offset = get(range, 'endOffset', 0)

  let text = current_completion.completion.text . suffix_text
  if empty(text)
    return default
  endif

  let delete_range = ''
  if end_offset - start_offset > 0
    let delete_bytes = end_offset - start_offset
    let delete_chars = strchars(strpart(getline('.'), 0, delete_bytes))
    " We insert a space, escape to normal mode, then delete the inserted space.
    " This lets us "accept" any auto-inserted indentation which is otherwise
    " removed when we switch to normal mode.
    " \"_ sequence makes sure to delete to the void register.
    " This way our current yank is not overridden.
    let delete_range = " \<Esc>\"_x0\"_d" . delete_chars . 'li'
  endif

  let insert_text = "\<C-R>\<C-O>=codeium#CompletionText()\<CR>"
  let s:completion_text = text

  if delta == 0
    let cursor_text = ''
  else
    let cursor_text = "\<C-O>:exe 'go' line2byte(line('.'))+col('.')+(" . delta . ")\<CR>"
  endif
  call codeium#server#Request('AcceptCompletion', {'metadata': codeium#server#RequestMetadata(), 'completion_id': current_completion.completion.completionId})
  return delete_range . insert_text . cursor_text
endfunction

# 用于处理从语言服务器返回的自动补全结果
# out 是 response 每行结果
function! s:HandleCompletionsResult(out, err, status) abort
  # 不存在 b:_codeium_completions 说明前面的请求存在异常
  if exists('b:_codeium_completions')
    # 文本拼接成一行
    let response_text = join(a:out, '')
    try
      # 解析 response 获取 completionItems 字段
      # 并存放到 b:_codeium_completions.items 字段里
      let response = json_decode(response_text)
      if get(response, 'code', v:null) isnot# v:null
        call codeium#log#Error('Invalid response from language server')
        call codeium#log#Error(response_text)
        call codeium#log#Error('stderr: ' . join(a:err, ''))
        call codeium#log#Exception()
        return
      endif
      let completionItems = get(response, 'completionItems', [])

      let b:_codeium_completions.items = completionItems
      # 设置为 0，准备呈现第一个自动补全结果
      let b:_codeium_completions.index = 0

      let b:_codeium_status = 2
      # 渲染当前选择的自动补全项
      call s:RenderCurrentCompletion()
    catch
      call codeium#log#Error('Invalid response from language server')
      call codeium#log#Error(response_text)
      call codeium#log#Error('stderr: ' . join(a:err, ''))
      call codeium#log#Exception()
    endtry
  endif
endfunction

# 用于获取当前自动完成菜单（popup menu）中被选中的项
function! s:GetCurrentCompletionItem() abort
  # 如果当前有打开的自动完成菜单
  # （即存在名为`b:_codeium_completions`的缓存变量，并且该变量包含了一个名为`'items'`的键和一个名为`'index'`的键），
  # 则返回目前菜单中被选中（或者当前光标所在的）项的值。
  # 如果当前没有自动完成菜单或者菜单中没有被选择的项（即`b:_codeium_completions.index >= len(b:_codeium_completions.items)`），
  # 则返回`v:null`，表示未选择自动完成项
  if exists('b:_codeium_completions') &&
        \ has_key(b:_codeium_completions, 'items') &&
        \ has_key(b:_codeium_completions, 'index') &&
        \ b:_codeium_completions.index < len(b:_codeium_completions.items)
    return get(b:_codeium_completions.items, b:_codeium_completions.index)
  endif

  return v:null
endfunction

let s:nvim_extmark_ids = []

function! s:ClearCompletion() abort
  if has('nvim')
    let namespace = nvim_create_namespace('codeium')
    for id in s:nvim_extmark_ids
      call nvim_buf_del_extmark(0, namespace, id)
    endfor
    let s:nvim_extmark_ids = []
  else
    # 移除所有匹配 CodeiumSuggestion 的文本属性
    # Codeium可能需要移除之前添加的文本属性，因为重复添加文本属性可能会导致显示错误。
    # 此外，如果该插件的用户在更改代码时使用了其他插件，这些插件可能会添加其自己的文本属性。
    # 如果这些属性没有正确清除，它们可能会与codeium添加的属性相互干扰，从而导致意外的或意料之外的显示问题。
    # 因此，为了确保正确的显示，清除所有之前添加的文本属性是一个良好的实践
    call prop_remove({'type': s:hlgroup, 'all': v:true})
  endif
endfunction

# 渲染当前的补全提示
function! s:RenderCurrentCompletion() abort
  # 为了避免重复添加文本属性，渲染前移除已有的 CodeiumSuggestion 文本属性
  call s:ClearCompletion()
  call codeium#RedrawStatusLine()

  # 如果当前模式不是插入模式、替换模式
  if mode() !~# '^[iR]'
    return ''
  endif
  if !get(g:, 'codeium_render', v:true)
    return
  endif

  # 获取选择的补全项
  let current_completion = s:GetCurrentCompletionItem()
  if current_completion is v:null
    return ''
  endif

  # current_completion 内容格式如下:
  # {
  # 	"completionParts": [{
  # 			"offset": "198",
  # 			"line": "11",
  # 			"type": "COMPLETION_PART_TYPE_INLINE",
  # 			"text": "log.Print(string(msg))",
  # 			"prefix": "^I//"
  # 		},
  # 		{
  # 			"offset": "198",
  # 			"line": "11",
  # 			"type": "COMPLETION_PART_TYPE_INLINE_MASK",
  # 			"text": "log.Print(string(msg))",
  # 			"prefix": "^I//"
  # 		}
  # 	],
  # 	"range": {
  # 		"endPosition": {
  # 			"col": "3",
  # 			"row": "11"
  # 		},
  # 		"startOffset": "195",
  # 		"endOffset": "198",
  # 		"startPosition": {
  # 			"row": "11"
  # 		}
  # 	},
  # 	"completion": {
  # 		"score": -1.297392,
  # 		"adjustedProbabilities": [1, 0.315791, 1, 1, 0.285158, 0.99971, 1, 1, 0.999999, 1],
  # 		"stop": "<|endoftext|>",
  # 		"completionId": "4dfcd7d3-b969-4a8d-b733-2ddcf27ab809",
  # 		"tokens": ["14", "6404", "13", "18557", "7", "8841", "7", "19662", "4008", "50256"],
  # 		"generatedLength": "10",
  # 		"decodedTokens": ["/", "log", ".", "Print", "(", "string", "(", "msg", "))", "<|endoftext|>"],
  # 		"text": "^I//log.Print(string(msg))",
  # 		"probabilities": [0.974924, 0.119652, 0.992313, 0.993949, 0.279444, 0.723794, 0.997891, 0.975285, 0.900782, 0.304406]
  # 	},
  # 	"source": "COMPLETION_SOURCE_TYPING_AS_SUGGESTED"
  # }
  
  let parts = get(current_completion, 'completionParts', [])

  let idx = 0
  let inline_cumulative_cols = 0
  let diff = 0
  for part in parts
    # 获取候选项对应的行号，与当前行比较，不相等则忽略该候选项
    let row = get(part, 'line', 0) + 1
    if row != line('.')
      call codeium#log#Warn('Ignoring completion, line number is not the current line.')
      continue
    endif
    if part.type ==# 'COMPLETION_PART_TYPE_INLINE'
      # 计算前缀的列号 
      let _col = inline_cumulative_cols + len(get(part, 'prefix', '')) + 1
      let inline_cumulative_cols = _col - 1
    else
      let _col = len(get(part, 'prefix', '')) + 1
    endif
    let text = part.text

    if (part.type ==# 'COMPLETION_PART_TYPE_INLINE' && idx == 0) || part.type ==# 'COMPLETION_PART_TYPE_INLINE_MASK'
      let completion_prefix = get(part, 'prefix', '')
      # completion_line 加上前缀，补全后的文本
      let completion_line = completion_prefix . text
      let full_line = getline(row)
      # full_line[0:len], len 为光标前面的字符串的长度
      # 获取光标前的文本
      let cursor_prefix = strpart(full_line, 0, col('.')-1)
      " 这段代码是用来计算自动补全候选项的前缀和当前光标前面的文本中的匹配长度
      " 这将用于后续根据匹配长度计算需要调整的偏移量
      let matching_prefix = 0
      for i in range(len(completion_line))
        if i < len(full_line) && completion_line[i] ==# full_line[i]
          let matching_prefix += 1
        else
          break
        endif
      endfor

      # 这段代码是根据前缀匹配结果，计算需要调整自动补全文本的偏移量（即 diff 变量）。
      # diff 变量值表明需要将自动补全文本向右移动多少
      if len(cursor_prefix) > len(completion_prefix)
        # 光标前的文本长度大于请求返回的前缀文本长度的话
        # (光标超出了补全的情况，好像用户添加了文本)
        # 无论匹配与否，我们都应该使用用户的文本
        " Case where the cursor is beyond the completion (as if it added text).
        " We should always consume text regardless of matching or not.
        " diff 表示用户新增的长度
        let diff = len(cursor_prefix) - len(completion_prefix)
      elseif len(cursor_prefix) < len(completion_prefix)
        " 光标在补全的前面，它可能只是光标移动到前面了
        " Case where the cursor is before the completion.
        " It could just be a cursor move, in which case the matching prefix goes
        " all the way to the completion prefix or beyond. Then we shouldn't do
        " anything.
        if matching_prefix >= len(completion_prefix)
          # 意味着自动补全文本前缀已经与光标前面的文本完全匹配
          let diff = matching_prefix - len(completion_prefix)
        else
          # 需要将自动补全文本向左移动，
          # 以便将未匹配的文本添加到光标前面的文本末尾
          let diff = len(cursor_prefix) - len(completion_prefix)
        endif
      endif
      if has('nvim') && diff > 0
        let diff = 0
      endif
      " Adjust completion. diff needs to be applied to all inline parts and is
      " done below.
      if diff < 0
        # diff < 0 表示当前自动补全文本前缀没有完全匹配，需要舍弃部分文字，使自动补全文本前缀与光标前面的文本完全匹配
        # 此时，将从自动补全的前缀中舍弃掉 `diff` 个字符位置，
        let text = completion_prefix[diff :] . text
      elseif diff > 0
        # diff > 0 表示光标前面的文本部分没有被匹配
        # 光标前面的文本长度大于自动补全前缀的长度，需要将候选项往左移动。
        # 此时，将从自动补全的文本中舍弃掉 `diff` 个字符位置，
        let text = text[diff :]
      endif
    endif

    if has('nvim')
      let _virtcol = virtcol([row, _col+diff])
      let data = {'id': idx + 1, 'hl_mode': 'combine', 'virt_text_win_col': _virtcol - 1}
      if part.type ==# 'COMPLETION_PART_TYPE_INLINE_MASK'
        let data.virt_text = [[text, s:hlgroup]]
      elseif part.type ==# 'COMPLETION_PART_TYPE_BLOCK'
        let lines = split(text, "\n", 1)
        if empty(lines[-1])
          call remove(lines, -1)
        endif
        let data.virt_lines = map(lines, { _, l -> [[l, s:hlgroup]] })
      else
        continue
      endif

      call add(s:nvim_extmark_ids, data.id)
      call nvim_buf_set_extmark(0, nvim_create_namespace('codeium'), row - 1, 0, data)
    else
      if part.type ==# 'COMPLETION_PART_TYPE_INLINE'
        # 将 text 作为虚拟文本添加到指定的 _col + diff 列的后面
        call prop_add(row, _col + diff, {'type': s:hlgroup, 'text': text})
      elseif part.type ==# 'COMPLETION_PART_TYPE_BLOCK'
        let text = split(part.text, "\n", 1)
        if empty(text[-1])
          call remove(text, -1)
        endif

        for line in text
          let num_leading_tabs = 0
          for c in split(line, '\zs')
            if c ==# "\t"
              let num_leading_tabs += 1
            else
              break
            endif
          endfor
          let line = repeat(' ', num_leading_tabs * shiftwidth()) . strpart(line, num_leading_tabs)
          call prop_add(row, 0, {'type': s:hlgroup, 'text_align': 'below', 'text': line})
        endfor
      endif
    endif

    let idx = idx + 1
  endfor
endfunction

function! codeium#Clear(...) abort
  let b:_codeium_status = 0
  call codeium#RedrawStatusLine()
  if exists('g:_codeium_timer')
    call timer_stop(remove(g:, '_codeium_timer'))
  endif

  " Cancel any existing request.
  if exists('b:_codeium_completions')
    let request_id = get(b:_codeium_completions, 'request_id', 0)
    if request_id > 0
      try
        call codeium#server#Request('CancelRequest', {'request_id': request_id})
      catch
        call codeium#log#Exception()
      endtry
    endif
    call s:RenderCurrentCompletion()
    unlet! b:_codeium_completions

  endif

  if a:0 == 0
    call s:RenderCurrentCompletion()
  endif
  return ''
endfunction

function! codeium#CycleCompletions(n) abort
  if s:GetCurrentCompletionItem() is v:null
    return
  endif

  let b:_codeium_completions.index += a:n
  let n_items = len(b:_codeium_completions.items)

  if b:_codeium_completions.index < 0
    let b:_codeium_completions.index += n_items
  endif

  let b:_codeium_completions.index %= n_items

  call s:RenderCurrentCompletion()
endfunction

function! codeium#Complete(...) abort
  # 2 个参数表示它是定时器执行过来的而非手动调用  
  if a:0 == 2
    let bufnr = a:1
    let timer = a:2

    # 传入的定时器与当前插件保存的定时器 _codeium_timer 是否是同一个
    # 不是的话表明该定时器已经被取消或已经被重新设置，不应该执行自动化补全操作
    if timer isnot# get(g:, '_codeium_timer', -1)
      return
    endif

    call remove(g:, '_codeium_timer')

    # 如果当前模式不是插入模式或者传入的缓冲区号与当前的缓冲区号不是同一个
    # 不应该执行补全操作
    if mode() !=# 'i' || bufnr !=# bufnr('')
      return
    endif
  endif

  # g:_codeium_timer 维护插件的唯一定时器
  # 停止现有的定时器，避免出现多个定时器同时工作的情况
  if exists('g:_codeium_timer')
    call timer_stop(remove(g:, '_codeium_timer'))
  endif

  if !codeium#Enabled()
    return
  endif

  if &encoding !=# 'latin1' && &encoding !=# 'utf-8'
    echoerr 'Only latin1 and utf-8 are supported'
    return
  endif

  # other_documents 保存除了当前文档外，所有文件类型非空的的文档信息
  let other_documents = []
  let current_bufnr = bufnr('%')
  # bufloaded	只包含已载入的缓冲区
  let loaded_buffers = getbufinfo({'bufloaded':1})
  for buf in loaded_buffers
    # 除了当前文档，其他文件类型非空的文档  
    if buf.bufnr != current_bufnr && getbufvar(buf.bufnr, '&filetype') !=# ''
      # codeium#doc#GetDocument 获取 buf 文档对象，保存到 other_documents  
      call add(other_documents, codeium#doc#GetDocument(buf.bufnr, 1, 1))
    endif
  endfor

  let data = {
        \ 'metadata': codeium#server#RequestMetadata(), # 获取请求meta参数，比如 apiKey
        \ 'document': codeium#doc#GetDocument(bufnr(), line('.'), col('.')), # 当前文档对象
        \ 'editor_options': codeium#doc#GetEditorOptions(), # 获取编辑器的相关信息，比如 tab_size
        \ 'other_documents': other_documents # 其他加载的文档对象
        \ }

  # 避免重复请求
  if exists('b:_codeium_completions.request_data') && b:_codeium_completions.request_data ==# data
    return
  endif

  " Add request id after we check for identical data.
  let request_data = deepcopy(data)

  # 构造一个唯一的请求 ID
  let s:request_nonce += 1
  let request_id = s:request_nonce
  let data.metadata.request_id = request_id

  try
    let b:_codeium_status = 1
    # 向服务器发起请求，并传入请求数据和处理结果的回调函数
    let request_job = codeium#server#Request('GetCompletions', data, function('s:HandleCompletionsResult', []))

    # 将请求信息保存到 b:_codeium_completions
    let b:_codeium_completions = {
          \ 'request_data': request_data,
          \ 'request_id': request_id,
          \ 'job': request_job
          \ }
  catch
    call codeium#log#Exception()
  endtry
endfunction

# 在 codeium#Complete 的基础上进行封装，在 vim 等待输入 sleep 75ms 执行补全
function! codeium#DebouncedComplete(...) abort
  # 清除之前的自动补全  
  call codeium#Clear()
  # 如果关闭了 codeium 的自动触发补全功能，则退出
  if get(g:, 'codeium_manual', v:false)
    return
  endif
  # '' 表示获取当前缓冲区编号
  let current_buf = bufnr('')
  let delay = get(g:, 'codeium_idle_delay', 75)
  # 在 vim 等待输入时 sleep 75ms 后执行 codeium#Complete 函数
  # [current_buf] 是 codeium#Complete 的参数，
  # 目的是告诉回调函数当前触发自动补全操作的缓冲区编号。这个参数在回调函数中可能有用，因为在Vim中可以同时打开多个缓冲区，每个缓冲区中都可能需要自动补全操作
  # 保存定时器号到全局变量，
  # 同时定时器号会作为参数自动传入 timer_start 的回调函数，在里面会校验外部的
  # 定时器号
  let g:_codeium_timer = timer_start(delay, function('codeium#Complete', [current_buf]))
endfunction

function! codeium#CycleOrComplete() abort
  if s:GetCurrentCompletionItem() is v:null
    call codeium#Complete()
  else
    call codeium#CycleCompletions(1)
  endif
endfunction

function! codeium#GetStatusString(...) abort
  let s:using_codeium_status = 1
  if (!codeium#Enabled())
    return 'OFF'
  endif
  if mode() !~# '^[iR]'
    return ' ON'
  endif
  if exists('b:_codeium_status') && b:_codeium_status > 0
    if b:_codeium_status == 2
      if exists('b:_codeium_completions') &&
            \ has_key(b:_codeium_completions, 'items') &&
            \ has_key(b:_codeium_completions, 'index')
        if len(b:_codeium_completions.items) > 0
          return printf('%d/%d', b:_codeium_completions.index + 1, len(b:_codeium_completions.items))
        else
          return ' 0 '
        endif
      endif
    endif
    if b:_codeium_status == 1
      return ' * '
    endif
    return ' 0 '
  endif
  return '   '
endfunction

function! codeium#RedrawStatusLine() abort
  if s:using_codeium_status
    redrawstatus
  endif
endfunction

function! codeium#ServerLeave() abort
  if !exists('g:codeium_server_job') || g:codeium_server_job is v:null
    return
  endif

  if has('nvim')
    call jobstop(g:codeium_server_job)
  else
    call job_stop(g:codeium_server_job)
  endif
endfunction
