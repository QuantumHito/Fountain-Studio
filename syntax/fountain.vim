" Inline Fountain markup: emphasis, notes and the boneyard.
"
" Structural elements (scene headings, characters, transitions...) need
" surrounding lines for context, so they are highlighted from Lua with extmarks
" instead -- see lua/fountain-studio/render.lua.

if exists("b:current_syntax")
  finish
endif

syntax spell toplevel

" Defined narrowest first: in Vim the item defined last wins at a given
" position, so *** beats ** beats *.
syn region fountainItalic     matchgroup=Conceal start=/\*\ze\S/     end=/\S\zs\*/     oneline concealends contains=@Spell
syn region fountainBold       matchgroup=Conceal start=/\*\*\ze\S/   end=/\S\zs\*\*/   oneline concealends contains=@Spell
syn region fountainBoldItalic matchgroup=Conceal start=/\*\*\*\ze\S/ end=/\S\zs\*\*\*/ oneline concealends contains=@Spell
syn region fountainUnderline  matchgroup=Conceal start=/\<_\ze\S/    end=/\S\zs_\>/    oneline concealends contains=@Spell

syn region fountainNote     start=/\[\[/ end=/\]\]/ contains=@Spell
syn region fountainBoneyard start=+/\*+  end=+\*/+  contains=@Spell

hi def link fountainNote FountainNote
hi def link fountainBoneyard FountainBoneyard
hi def link fountainBold FountainBold
hi def link fountainItalic FountainItalic
hi def link fountainBoldItalic FountainBoldItalic
hi def link fountainUnderline FountainUnderline

let b:current_syntax = "fountain"
