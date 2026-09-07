# fountain-studio.nvim

Screenplay formatting for `.fountain` files in Neovim / LazyVim. The buffer is
centered on screen at the width of a real page, and every element is placed
where a rendered PDF would put it — character cues and dialogue indented,
transitions flush right, scene headings bold.

Nothing is written to the file. Indentation is drawn with inline virtual text
and markers are hidden with conceal, so the bytes on disk stay a plain,
unindented Fountain file. Turn the plugin off and the text is exactly as you
typed it.

**Status: stage two.** Layout, element alignment, highlighting and the
left-margin scene outline are done — see [What's next](#whats-next).

## What it looks like

The file you are editing:

```fountain
MAYA
Then the answer is *definitely* no.

DANNY enters, coat still wet, holding two coffees like a peace offering.

DANNY
I brought bribes. And an apology, and a theory about why the mayor's office called the publisher at eleven at night.

MAYA
(taking one)
You brought lukewarm bribes.

CUT TO:

EXT. PARKING GARAGE - CONTINUOUS
```

What you see while editing it:

```
|                                                                                            |
|                                      MAYA                                                  |
|                          Then the answer is definitely no.                                 |
|                                                                                            |
|                DANNY enters, coat still wet, holding two coffees like a                    |
|                peace offering.                                                             |
|                                                                                            |
|                                      DANNY                                                 |
|                          I brought bribes. And an apology,                                 |
|                          and a theory about why the mayor's                                |
|                          office called the publisher at                                    |
|                          eleven at night to talk about a                                   |
|                          story that officially does not                                    |
|                          exist yet.                                                        |
|                                                                                            |
|                                      MAYA                                                  |
|                                (taking one)                                                |
|                          You brought lukewarm bribes.                                      |
|                                                                                            |
|                                                                     CUT TO:                |
|                                                                                            |
|                EXT. PARKING GARAGE - CONTINUOUS                                            |
|                                                                                            |
```

## The scene outline

The left margin lists the scenes in script order with how long each one runs,
measured the way a production board measures it — in eighths of a page. The
scene the cursor is in is highlighted, the list scrolls to follow it, and the
header carries the running length of the whole script.

```
SCENES           1 3/8                        DANNY
ACT ONE                           I brought bribes. And an apology,
 1 I. NEWSROOM - N… 6/8           and a theory about why the mayor's
 2 E. PARKING GARA… 3/8           office called the publisher at
 3 THE ROOF - LATER 1/8           eleven at night to talk about a
                                  story that officially does not
                                  exist yet.

                                              MAYA
                                        (taking one)
                                  You brought lukewarm bribes.
```

`#` sections appear as dividers between scenes, so acts show up in the list.
Slugs are abbreviated (`INT.` → `I.`) to buy columns for the location, and the
whole thing is dropped rather than squeezed when the margin is narrower than
`outline.min_width`. Lengths are an estimate from the rendered line count at 55
lines to the page, not a true pagination pass — close enough to see at a glance
that a scene is running long.

Re-measuring walks the whole script, so it waits for a pause in typing: about
30 ms on a 240-page script, and it never runs mid-keystroke. Following the
cursor is separate and immediate.

## The measure

A US Letter page set in 12pt Courier is 10 characters per inch. With the
standard 1.5" left and 1.0" right margins that leaves a 6.0" measure, so:

| Element | Page position | Columns |
|---|---|---|
| Action, scene headings | 1.5" – 7.5" | indent 0, width **60** |
| Dialogue | 2.5" – 6.0" | indent 10, width 35 |
| Parenthetical | 3.1" – 5.6" | indent 16, width 25 |
| Character cue | 3.7" | indent 22 |
| Transition | flush right | ends at column 60 |

Action paragraphs therefore break exactly where they break on the page, and so
does dialogue: wrapped dialogue keeps its own 35-column measure instead of
running to the page edge, so paragraph shape is what it will be in the PDF.

If the terminal is too narrow for a 60-column page, the whole page — indents and
measures included — is scaled down proportionally rather than clipped, and a
short warning is issued once.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim) / LazyVim:

```lua
{
  "QuantumHito/Fountain-Studio",
  ft = "fountain",
  -- Neovim does not know the extension yet, and lazy-loading by filetype needs
  -- it to, so register it at startup.
  init = function()
    vim.filetype.add({ extension = { fountain = "fountain", spmd = "fountain" } })
  end,
  opts = {},
}
```

Working on the plugin itself? Point lazy at the checkout instead:

```lua
{ dir = "~/code/Fountain-Studio", ft = "fountain", init = ..., opts = {} }
```

Requires Neovim 0.10+ (inline virtual text). Verify a setup with
`:checkhealth fountain-studio`.

## Commands

| Command | What it does |
|---|---|
| `:FountainZen` | Toggle the centered page |
| `:FountainOutline` | Toggle the scene outline in the left margin |
| `:FountainFormat` | Toggle the visual formatting in this buffer (raw view) |
| `:FountainInspect` | Report how the line under the cursor is being classified and placed |

`:q` in the page quits the file as it normally would, rather than only dropping
the layout — and if there are unsaved changes it refuses, exactly like `:q` in an
ordinary window, leaving the page and your edits where they were.

The formatting does not depend on the centered layout: with `zen.auto = false`
the page measure still holds in an ordinary window, action breaking at column 60
and dialogue at its own 35.

Two `User` autocmd events fire alongside the layout, for statusline or plugin
integration: `FountainStudioZenOpen` and `FountainStudioZenClose`.

## Configuration

`opts` is merged over these defaults; everything is in terminal columns.

```lua
{
  filetypes = { "fountain" },

  width = 60,        -- the action measure: 6.0" at 10 cpi
  min_width = 32,    -- below this, stop trying to hold the standard page
  min_margin = 2,    -- blank columns kept either side of the page

  indents = {
    action = 0, scene_heading = 0,
    dialogue = 10, parenthetical = 16, character = 22,
    lyrics = 10, section = 0, synopsis = 0, page_break = 0, title_page = 0,
  },
  measures = { -- how wide a block gets before it wraps
    dialogue = 35, parenthetical = 25, character = 38, lyrics = 35,
  },

  wrap_to_measure = true,  -- wrap dialogue at its own measure, not the page edge
  conceal_markers = true,  -- hide `.` `@` `!` `>` `~` `^`, shown again on the cursor line
  align = true,            -- draw the indentation
  highlight = true,        -- highlight elements

  transition_patterns = {  -- beyond Fountain's "uppercase line ending in TO:"
    "^FADE OUT%.?$", "^FADE TO BLACK%.?$", "^CUT TO BLACK%.?$", "^THE END%.?$",
  },

  overscan = 40,   -- lines rendered beyond the viewport
  lookback = 200,  -- how far back to re-sync the parser

  zen = {
    enabled = true,
    auto = true,      -- center the page as soon as a script is opened
    backdrop = true,  -- blank out everything behind it
    offset = 0,       -- nudge the page left or right
    pad_top = 0,
    -- The page is an editing surface, so it takes the editor's own colours
    -- rather than the float colours a theme reserves for popups.
    winhighlight = "NormalFloat:Normal,FloatBorder:Normal,EndOfBuffer:Normal",
  },

  outline = {
    enabled = true,
    width = 26,        -- capped to whatever the left margin actually is
    min_width = 14,    -- narrower than this and the margin is left blank
    gap = 1,           -- blank columns between the outline and the page
    header = true,     -- a SCENES header carrying the running total
    sections = true,   -- show `#` sections as dividers between scenes
    units = "eighths", -- "eighths" (1 3/8) or "decimal" (1.4)
    abbreviate = true, -- INT. -> I., to buy columns for the slug
    page_lines = 55,   -- lines of text on a printed page
  },

  winopts = { -- applied to the window showing the script
    wrap = true, linebreak = true, breakindent = true,
    number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0",
    cursorline = false, cursorcolumn = false, colorcolumn = "", list = false,
    spell = false, conceallevel = 2, concealcursor = "",
  },
  bufopts = { textwidth = 0, expandtab = true },
}
```

Every highlight group is defined with `default`, so a colorscheme or your own
`:highlight` wins: `FountainSceneHeading`, `FountainCharacter`,
`FountainParenthetical`, `FountainTransition`, `FountainCentered`,
`FountainSection`, `FountainSynopsis`, `FountainLyrics`, `FountainTitlePage`,
`FountainPageBreak`, `FountainNote`, `FountainBoneyard`, `FountainBold`,
`FountainItalic`, `FountainBoldItalic`, `FountainUnderline`, and
`FountainStudioBackdrop` for the blank margins. The outline has
`FountainOutlineHeader`, `FountainOutlineNumber`, `FountainOutlineHeading`,
`FountainOutlineLength`, `FountainOutlineSection`, `FountainOutlineCurrent` and
`FountainOutlineEmpty`.

`FountainStudioIndent`, which draws the virtual indentation, is deliberately
attribute-less: it inherits the background of whatever window it is drawn in, so
the indent can never show up as a block of a different colour.

## How it works

| Piece | File |
|---|---|
| Element classification | `lua/fountain-studio/parser.lua` |
| Indentation, measures, highlighting | `lua/fountain-studio/render.lua` |
| Centered page and backdrop | `lua/fountain-studio/zen.lua` |
| Scene outline and page counts | `lua/fountain-studio/outline.lua` |
| Emphasis, notes, boneyard | `syntax/fountain.vim` |

The parser is line-at-a-time and re-syncs at blank lines, so only the visible
region plus a margin is ever re-parsed — a keystroke re-renders about a screen's
worth of lines, not the script.

Wrapped dialogue works by a small trick: Neovim wraps inline virtual text like
ordinary text, so padding inserted at a break point spills past the right edge of
the window and its tail becomes the indent of the next screen row.

## Tests

```bash
nvim -l tests/run.lua   # from this directory; exits non-zero on failure
```

86 checks covering element classification, geometry, wrapping, the layout math,
the outline's scene detection and page arithmetic, and an end-to-end pass over
`examples/sample.fountain` — including a check that writing the buffer leaves
the file byte-identical, and that a refused `:q` keeps unsaved work on screen.

## What's next

- **Right margin.** Still blank and reserved.
- Jumping to a scene from the outline, and reordering scenes from it.
- Page-boundary markers down the side of the page (the 55-line rule).
- Dual dialogue side by side, rather than one cue after the other.
- Moving the rendering onto a decoration provider, so it follows the viewport
  Neovim is actually drawing instead of reacting to scroll events.

## License

[MIT](LICENSE).
