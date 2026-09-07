# fountain-studio.nvim

Screenplay formatting for `.fountain` files in Neovim / LazyVim. The buffer is
centered on screen at the width of a real page, and every element is placed
where a rendered PDF would put it — character cues and dialogue indented,
transitions flush right, scene headings bold.

Nothing is written to the file. Indentation is drawn with inline virtual text
and markers are hidden with conceal, so the bytes on disk stay a plain,
unindented Fountain file. Turn the plugin off and the text is exactly as you
typed it.

**Status: stage one.** Layout, element alignment and highlighting are done. The
scene outline in the left margin is next — see [What's next](#whats-next).

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

The repository is private, so lazy needs git credentials that can read it. Over
SSH that means an agent key and:

```lua
require("lazy").setup(specs, { git = { url_format = "git@github.com:%s.git" } })
```

Over HTTPS, a credential helper (`gh auth setup-git`, say) is enough.

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
`FountainStudioBackdrop` for the blank margins.

## How it works

| Piece | File |
|---|---|
| Element classification | `lua/fountain-studio/parser.lua` |
| Indentation, measures, highlighting | `lua/fountain-studio/render.lua` |
| Centered page and backdrop | `lua/fountain-studio/zen.lua` |
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

66 checks covering element classification, geometry, wrapping, the layout math,
and an end-to-end pass over `examples/sample.fountain` — including a check that
writing the buffer leaves the file byte-identical, and that a refused `:q` keeps
unsaved work on screen.

## What's next

- **Left margin: the scene outline.** Scenes in script order with their page
  count, in the blank column to the left of the page, kept in sync as you write.
- **Right margin.** Left blank and reserved.
- Page-boundary markers down the side of the page (the 55-line rule).
- Dual dialogue side by side, rather than one cue after the other.
