" Initialize -----------------------------------------------------------------
let s:plugin_name = 'quick-scope'

if exists('g:loaded_quick_scope')
  finish
endif

let g:loaded_quick_scope = 1

if &compatible
  echoerr s:plugin_name . " won't load in Vi-compatible mode."
  finish
endif

if v:version < 701 || (v:version == 701 && !has('patch040'))
  echoerr s:plugin_name . ' requires Vim running in version 7.1.040 or later.'
  finish
endif

unlet! s:plugin_name

" Save cpoptions and reassign them later. See :h use-cpo-save.
let s:cpo_save = &cpo
set cpo&vim

" Autocommands ---------------------------------------------------------------
augroup quick_scope
  autocmd!
  autocmd ColorScheme * call s:set_highlight_colors()
augroup END

" Options --------------------------------------------------------------------
if !exists('g:qs_enable')
  let g:qs_enable = 1
endif

if !exists('g:qs_max_chars')
  " Disable on long lines for performance
  let g:qs_max_chars = 1000
endif

if !exists('g:qs_accepted_chars')
  let g:qs_accepted_chars = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9']
endif

if !exists('g:qs_highlight_on_keys')
  " Vanilla mode. Highlight on cursor movement.
  augroup quick_scope
    autocmd CursorMoved,InsertLeave,ColorScheme * call s:unhighlight_line() | call s:highlight_line(2, g:qs_accepted_chars)
    autocmd InsertEnter * call s:unhighlight_line()
  augroup END
else
  " Highlight on key press. Set an 'augmented' mapping for each defined key.
  for motion in filter(g:qs_highlight_on_keys, "v:val =~# '^[fFtT]$'")
    for mapmode in ['nnoremap', 'onoremap', 'xnoremap']
      execute printf(mapmode . ' <unique> <silent> <expr> %s <sid>ready() . <sid>aim("%s") . <sid>reload() . <sid>double_tap()', motion, motion)
    endfor
  endfor
endif

" User commands --------------------------------------------------------------
function! s:toggle()
  if g:qs_enable
    let g:qs_enable = 0
    call <sid>unhighlight_line()
  else
    let g:qs_enable = 1
    doautocmd CursorMoved
  endif
endfunction

command! -nargs=0 QuickScopeToggle call s:toggle()

" Plug mappings --------------------------------------------------------------
nnoremap <silent> <plug>(QuickScopeToggle) :call <sid>toggle()<cr>
xnoremap <silent> <plug>(QuickScopeToggle) :<c-u>call <sid>toggle()<cr>

" Colors ---------------------------------------------------------------------
" Set the colors used for highlighting.
function! s:set_highlight_colors()
  " Priority for overruling other highlight matches.
  let s:priority = 1

  " Highlight group marking first appearance of characters in a line.
  let s:hi_group_primary = 'QuickScopePrimary'
  execute 'highlight default link ' . s:hi_group_primary . ' Function'

  " Highlight group marking second appearance of characters in a line.
  let s:hi_group_secondary = 'QuickScopeSecondary'
  execute 'highlight default link ' . s:hi_group_secondary . ' Define'

  " Highlight group marking dummy cursor when quick-scope is enabled on key
  " press.
  let s:hi_group_cursor = 'QuickScopeCursor'
  execute 'highlight default link ' . s:hi_group_cursor . ' Cursor'
endfunction

call s:set_highlight_colors()

" Main highlighting functions ------------------------------------------------
" Apply the highlights for each highlight group based on pattern strings.
"
" Arguments are expected to be lists of two items.
function! s:apply_highlight_patterns(patterns)
  let [patt_p, patt_s] = a:patterns
  if !empty(patt_p)
    " Highlight columns corresponding to matched characters.
    "
    " Ignore the leading | in the primary highlights string.
    call matchadd(s:hi_group_primary, '\v%' . line('.') . 'l(' . patt_p[1:] . ')', s:priority)
  endif
  if !empty(patt_s)
    call matchadd(s:hi_group_secondary, '\v%' . line('.') . 'l(' . patt_s[1:] . ')', s:priority)
  endif
endfunction

" Keep track of which characters have a secondary highlight (but no primary
" highlight) and store them in :chars_s. Used when g:qs_highlight_on_keys is
" active to decide whether to trigger an extra highlight.
function! s:save_chars_with_secondary_highlights(chars)
  let [char_p, char_s] = a:chars

  if !empty(char_p)
    " Do nothing
  elseif !empty(char_s)
    call add(s:chars_s, char_s)
  endif
endfunction

" Set or append to the pattern strings for the highlights.
function! s:add_to_highlight_patterns(patterns, highlights)
  let [patt_p, patt_s] = a:patterns
  let [hi_p, hi_s] = a:highlights

  " If there is a primary highlight for the last word, add it to the primary
  " highlight pattern.
  if hi_p > 0
    let patt_p = printf('%s|%%%sc', patt_p, hi_p)
  elseif hi_s > 0
    let patt_s = printf('%s|%%%sc', patt_s, hi_s)
  endif

  return [patt_p, patt_s]
endfunction

" Finds which characters to highlight and returns their column positions as a
" pattern string.
function! s:get_highlight_patterns(line, cursor, end, targets)
  " Keeps track of the number of occurrences for each target
  let occurrences = {}

  " Patterns to match the characters that will be marked with primary and
  " secondary highlight groups, respectively
  let [patt_p, patt_s] = ['', '']

  " Indicates whether this is the first word under the cursor. We don't want
  " to highlight any characters in it.
  let is_first_word = 1

  " We want to skip the first char as this is the char the cursor is at
  let is_first_char = 1

  " The position of a character in a word that will be given a highlight. A
  " value of 0 indicates there is no character to highlight.
  let [hi_p, hi_s] = [0, 0]

  " The (next) characters that will be given a highlight. Used by
  " save_chars_with_secondary_highlights() to see whether an extra highlight
  " should be triggered if g:qs_highlight_on_keys is active.
  let [char_p, char_s] = ['', '']

  " If 1, we're looping forwards from the cursor to the end of the line;
  " otherwise, we're looping from the cursor to the beginning of the line.
  let direction = a:cursor < a:end ? 1 : 0

  " find the character index i and the byte index c
  " of the current cursor position
  let c = 1
  let i = 0
  let char = ''
  while c != a:cursor
    let char = matchstr(a:line, '.', byteidx(a:line, i))
    let c += len(char)
    let i += 1
  endwhile

  " reposition cursor to end of the char's composing bytes
  if !direction
    let c += len(matchstr(a:line, '.', byteidx(a:line, i))) - 1
  endif

  " catch cases where multibyte chars may result in c not exactly equal to
  " a:end
  while (direction && c <= a:end || !direction && c >= a:end)

    let char = matchstr(a:line, '.', byteidx(a:line, i))

    " Skips the first char as it is the char the cursor is at
    if is_first_char

      let is_first_char = 0

    " Don't consider the character for highlighting, but mark the position
    " as the start of a new word.
    "
    " Check for a <space> as a first condition for optimization.
    elseif char ==? "\<space>" || index(a:targets, char) == -1 || empty(char)
      if !is_first_word
        let [patt_p, patt_s] = s:add_to_highlight_patterns([patt_p, patt_s], [hi_p, hi_s])
      endif

      " We've reached a new word, so reset any highlights.
      let [hi_p, hi_s] = [0, 0]
      let [char_p, char_s] = ['', '']

      let is_first_word = 0
    else
      if has_key(occurrences, char)
        let occurrences[char] += 1
      else
        let occurrences[char] = 1
      endif

      if !is_first_word
        let char_occurrences = get(occurrences, char)

        " If the search is forward, we want to be greedy; otherwise, we
        " want to be reluctant. This prioritizes highlighting for
        " characters at the beginning of a word.
        "
        " If this is the first occurrence of the letter in the word,
        " mark it for a highlight.
        " If we are looking backwards, c will point to the end of the
        " end of composing bytes so we adjust accordingly
        " eg. with a multibyte char of length 3, c will point to the
        " 3rd byte. Minus (len(char) - 1) to adjust to 1st byte
        if char_occurrences == 1 && ((direction == 1 && hi_p == 0) || direction == 0)
          let hi_p = c - (1 - direction) * (len(char) - 1)
          let char_p = char
        elseif char_occurrences == 2 && ((direction == 1 && hi_s == 0) || direction == 0)
          let hi_s = c - (1 - direction) * (len(char)- 1)
          let char_s = char
        endif
      endif
    endif

    " update i to next character
    " update c to next byteindex
    if direction == 1
      let i += 1
      let c += strlen(char)
    else
      let i -= 1
      let c -= strlen(char)
    endif
  endwhile

  let [patt_p, patt_s] = s:add_to_highlight_patterns([patt_p, patt_s], [hi_p, hi_s])

  if exists('g:qs_highlight_on_keys')
    call s:save_chars_with_secondary_highlights([char_p, char_s])
  endif

  return [patt_p, patt_s]
endfunction

" The direction can be 0 (backward), 1 (forward) or 2 (both). Targets are the
" characters that can be highlighted.
function! s:highlight_line(direction, targets)
  if g:qs_enable && (!exists('b:qs_local_disable') || !b:qs_local_disable)
    let line = getline(line('.'))
    let len = strlen(line)
    let pos = col('.')

    if !empty(line) && len <= g:qs_max_chars
      " Highlight after the cursor.
      if a:direction != 0
        let [patt_p, patt_s] = s:get_highlight_patterns(line, pos, len, a:targets)
        call s:apply_highlight_patterns([patt_p, patt_s])
      endif

      " Highlight before the cursor.
      if a:direction != 1
        let pos -= 2
        if pos < 0 | let pos = 0 | endif

        let [patt_p, patt_s] = s:get_highlight_patterns(line, pos, -1, a:targets)
        call s:apply_highlight_patterns([patt_p, patt_s])
      endif
    endif
  endif
endfunction

function! s:unhighlight_line()
  for m in filter(getmatches(), printf('v:val.group ==# "%s" || v:val.group ==# "%s"', s:hi_group_primary, s:hi_group_secondary))
    call matchdelete(m.id)
  endfor
endfunction

" Save the value of s:hi_group_secondary to preserve customization before
" changing it as a result of a double_tap
function! s:save_secondary_highlight()
  if &verbose
    let s:saved_verbose = &verbose
    set verbose=0
  endif

  redir => s:saved_secondary_highlight
  execute 'silent highlight ' . s:hi_group_secondary
  redir END

  if exists('s:saved_verbose')
    execute 'set verbose=' . s:saved_verbose
  endif

  let s:saved_secondary_highlight = substitute(s:saved_secondary_highlight, '^.*xxx ', '', '')
endfunction

" Reset s:hi_group_secondary to its saved value after it was changed as a result
" of a double_tap
function! s:reset_saved_secondary_highlight()
  if s:saved_secondary_highlight =~# '^links to '
    let s:saved_secondary_highlight = substitute(s:saved_secondary_highlight, '^links to ', '', '')
    execute 'highlight! link ' . s:hi_group_secondary . ' ' . s:saved_secondary_highlight
  else
    execute 'highlight ' . s:hi_group_secondary . ' ' . s:saved_secondary_highlight
  endif
endfunction

" Highlight on key press -----------------------------------------------------
" Manage state for keeping or removing the extra highlight after triggering a
" highlight on key press.
"
" State can be 0 (extra highlight has just been triggered), 1 (the cursor has
" moved while an extra highlight is active), or 2 (cancel an active extra
" highlight).
function! s:handle_extra_highlight(state)
  if a:state == 0
    let s:cursor_moved_count = 0
  elseif a:state == 1
    let s:cursor_moved_count = s:cursor_moved_count + 1
  endif

  " If the cursor has moved more than once since the extra highlight has been
  " active (or the state is 2), reset the extra highlight.
  if exists('s:cursor_moved_count') && (a:state == 2 ||  s:cursor_moved_count > 1)
    call s:unhighlight_line()
    call s:reset_saved_secondary_highlight()
    autocmd! quick_scope CursorMoved
  endif
endfunction

" Set or reset flags and state for highlighting on key press.
function! s:ready()
  " Direction of highlight search. 0 is backward, 1 is forward
  let s:direction = 0

  " The corresponding character to f,F,t or T
  let s:target = ''

  " Position of where a dummy cursor should be placed.
  let s:cursor = 0

  " Terminal and gui cursors which will be hidden and shown.
  let s:t_ve = &t_ve
  let s:guicursor = &guicursor

  " Characters with secondary highlights. Modified by get_highlight_patterns()
  let s:chars_s = []

  call s:handle_extra_highlight(2)

  " Intentionally return an empty string that will be concatenated with the
  " return values from aim(), reload() and double_tap().
  return ''
endfunction

" Returns {character motion}{captured char} (to map to a character motion) to
" emulate one as closely as possible.
function! s:aim(motion)
  if (a:motion ==# 'f' || a:motion ==# 't')
    let s:direction = 1
  else
    let s:direction = 0
  endif

  " Add a dummy cursor since calling getchar() places the actual cursor on
  " the command line.
  let s:cursor = matchadd(s:hi_group_cursor, '\%#', s:priority + 1)

  " Save and hide the cursor on the command line.
  let s:t_ve = &t_ve
  let s:guicursor = &guicursor

  set t_ve=
  set guicursor=n:block-NONE

  " Silence 'Type :quit<Enter> to exit Vim' message on <c-c> during a
  " character search.
  "
  " This line also causes getchar() to cleanly cancel on a <c-c>.
  execute 'nnoremap <silent> <c-c> <c-c>'

  call s:highlight_line(s:direction, g:qs_accepted_chars)

  redraw

  " Store and capture the target for the character motion.
  let s:target = nr2char(getchar())

  return a:motion . s:target
endfunction

" Cleanup after a character motion is executed.
function! s:reload()
  " Remove dummy cursor
  call matchdelete(s:cursor)

  " Restore the cursor on the command line.
  set guicursor&
  let &t_ve = s:t_ve
  let &guicursor = s:guicursor

  " Restore default <c-c> functionality
  execute 'nmap <c-c> <Plug>SearchantStop'

  call s:unhighlight_line()

  " Intentionally return an empty string.
  return ''
endfunction

" Trigger an extra highlight for a target character only if it originally had
" a secondary highlight.
function! s:double_tap()
  if index(s:chars_s, s:target) != -1
    " Warning: slight hack below. Although the cursor has already moved by
    " this point, col('.') won't return the updated cursor position until the
    " invoking mapping completes. So when highlight_line() is called here, the
    " first occurrence of the target will be under the cursor, and the second
    " occurrence will be where the first occurence should have been.
    call s:highlight_line(s:direction, {expand(s:target) : ''})

    " Unhighlight only primary highlights (i.e., the character under the
    " cursor).
    for m in filter(getmatches(), printf('v:val.group ==# "%s"', s:hi_group_primary))
      call matchdelete(m.id)
    endfor

    " Temporarily change the second occurrence highlight color to a primary
    " highlight color.
    call s:save_secondary_highlight()
    execute 'highlight! link ' . s:hi_group_secondary . ' ' . s:hi_group_primary

    " Set a temporary event to keep track of when to reset the extra
    " highlight.
    augroup quick_scope
      autocmd CursorMoved * call s:handle_extra_highlight(1)
    augroup END

    call s:handle_extra_highlight(0)
  endif

  " Intentionally return an empty string.
  return ''
endfunction

let &cpo = s:cpo_save
unlet s:cpo_save
