-- Configuration and page geometry.
--
-- All measurements are in terminal columns. A US Letter screenplay page set in
-- 12pt Courier is 10 characters per inch: a 1.5" left margin and a 1.0" right
-- margin leave a 6.0" measure, so action fills exactly 60 columns. Every other
-- element is placed relative to that action margin, using the same offsets a
-- rendered PDF uses.
local M = {}

M.defaults = {
  -- Filetypes treated as Fountain scripts.
  filetypes = { "fountain" },

  -- Width of the action measure, in columns. 60 = 6.0" at 10 cpi.
  width = 60,

  -- If the terminal cannot fit `width` plus margins, shrink to what fits but
  -- never below this. Below `min_width` the plugin gives up on the standard
  -- measure and simply uses whatever room there is.
  min_width = 32,

  -- Columns of blank space to keep on each side of the page when centering.
  min_margin = 2,

  -- Indents relative to the action margin (column 0 of the measure), in
  -- columns, matching a rendered screenplay page:
  --   dialogue      2.5" from page edge -> 10
  --   parenthetical 3.1"                -> 16
  --   character     3.7"                -> 22
  indents = {
    action = 0,
    scene_heading = 0,
    character = 22,
    parenthetical = 16,
    dialogue = 10,
    lyrics = 10,
    section = 0,
    synopsis = 0,
    page_break = 0,
    title_page = 0,
  },

  -- Width of each element's measure, in columns -- how wide the block of text
  -- is allowed to get before it wraps, again matching a rendered page:
  --   dialogue      2.5" -> 6.0"  = 35
  --   parenthetical 3.1" -> 5.6"  = 25
  -- Elements not listed here get the full action measure.
  measures = {
    character = 38,
    parenthetical = 25,
    dialogue = 35,
    lyrics = 35,
  },

  -- Wrap dialogue and parentheticals at their own measure instead of at the
  -- page edge, keeping wrapped lines under the indent they started on.
  wrap_to_measure = true,

  -- Hide Fountain's forced-element markers -- the leading `.` `@` `!` `>` `~`
  -- and the dual-dialogue `^` -- so the page reads like a rendered one. They
  -- reappear on whichever line the cursor is on (see winopts.concealcursor),
  -- and the file itself is untouched.
  conceal_markers = true,

  -- Draw the virtual indentation (character / dialogue / transitions).
  align = true,
  -- Highlight elements (scene headings bold, transitions, parentheticals...).
  highlight = true,

  -- Extra transition patterns beyond the Fountain rule of "uppercase line
  -- ending in TO:". Lua patterns, matched against the trimmed, uppercased line.
  transition_patterns = {
    "^FADE OUT%.?$",
    "^FADE TO BLACK%.?$",
    "^CUT TO BLACK%.?$",
    "^THE END%.?$",
  },

  -- Rendering only touches the visible region plus this many lines of slack.
  overscan = 40,
  -- How far to look back for a blank line when re-syncing the parser.
  lookback = 200,

  zen = {
    enabled = true,
    -- Center the page automatically when a Fountain buffer is opened.
    auto = true,
    -- Blank out everything behind the page.
    backdrop = true,
    -- Nudge the page left (negative) or right (positive), in columns.
    offset = 0,
    -- Blank rows above the page.
    pad_top = 0,
    -- The page is an editing surface, so it takes the editor's own colours
    -- rather than the float colours a theme reserves for popups -- which also
    -- keeps it identical to the margins behind it.
    winhighlight = "NormalFloat:Normal,FloatBorder:Normal,EndOfBuffer:Normal",
  },

  -- Window-local options applied to the window showing the script.
  winopts = {
    wrap = true,
    linebreak = true,
    breakindent = true,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    cursorline = false,
    cursorcolumn = false,
    colorcolumn = "",
    list = false,
    spell = false,
    conceallevel = 2,
    concealcursor = "",
  },

  -- Buffer-local options applied to Fountain buffers.
  bufopts = {
    textwidth = 0,
    expandtab = true,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

function M.get()
  return M.options
end

return M
