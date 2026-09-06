-- Headless test suite:  nvim -l tests/run.lua   (from the plugin root)
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local passed, failed = 0, 0

local function ok(cond, name, extra)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(("  FAIL  %s%s\n"):format(name, extra and ("  -- " .. tostring(extra)) or ""))
    return
  end
  io.write(("  ok    %s\n"):format(name))
end

local function eq(got, want, name)
  ok(vim.deep_equal(got, want), name, ("got %s, want %s"):format(vim.inspect(got), vim.inspect(want)))
end

local function section(title)
  io.write("\n" .. title .. "\n")
end

vim.cmd("filetype plugin indent on")
vim.cmd("syntax on")

local fountain = require("fountain-studio")
fountain.setup({})

local parser = require("fountain-studio.parser")
local render = require("fountain-studio.render")
local zen = require("fountain-studio.zen")
local config = require("fountain-studio.config")

--------------------------------------------------------------------------- parser
section("parser")

local function kinds(text, at_bof)
  local lines = vim.split(text, "\n", { plain = true })
  return parser.scan(lines, { at_bof = at_bof, cfg = config.get() })
end

eq(kinds("INT. HOUSE - DAY\n\nHe waits.\n", true), { "scene_heading", "blank", "action", "blank" }, "scene heading and action")

eq(
  kinds("\nMAYA\n(quietly)\nGo home.\n\nShe leaves.", false),
  { "blank", "character", "parenthetical", "dialogue", "blank", "action" },
  "character block"
)

eq(kinds("\nCUT TO:\n\n", false), { "blank", "transition", "blank", "blank" }, "transition ending in TO:")
eq(kinds("\nFADE OUT.\n\n", false), { "blank", "transition", "blank", "blank" }, "FADE OUT. transition")
eq(kinds("\n> THE END <\n", false), { "blank", "centered", "blank" }, "centered text")
eq(kinds("\n.THE ROOF\n\n", false), { "blank", "scene_heading", "blank", "blank" }, "forced scene heading")
eq(kinds("\n@McCLANE\nYippee.\n", false), { "blank", "character", "dialogue", "blank" }, "forced character")
eq(kinds("\n!INT. NOT A HEADING\n", false), { "blank", "action", "blank" }, "forced action")
eq(kinds("\n# ACT ONE\n", false), { "blank", "section", "blank" }, "section")
eq(kinds("\n= A synopsis.\n", false), { "blank", "synopsis", "blank" }, "synopsis")
eq(kinds("\n===\n", false), { "blank", "page_break", "blank" }, "page break")
eq(kinds("Title: X\nAuthor: Y\n\nINT. HOUSE - DAY", true), { "title_page", "title_page", "blank", "scene_heading" }, "title page")

-- An uppercase line with a blank line after it is a transition candidate, not a
-- character cue.
eq(kinds("\nMAYA\n\n", false), { "blank", "action", "blank", "blank" }, "lone uppercase line is not a cue")
eq(kinds("\nMAYA ^\nObviously.\n", false), { "blank", "character", "dialogue", "blank" }, "dual dialogue cue")
eq(kinds("\nDANNY (O.S.)\nIt's me.\n", false), { "blank", "character", "dialogue", "blank" }, "cue with extension")

--------------------------------------------------------------------------- geometry
section("geometry")

eq(render.indent_for("action", "He waits.", 60), 0, "action sits on the margin")
eq(render.indent_for("dialogue", "Go home.", 60), 10, "dialogue indent")
eq(render.indent_for("parenthetical", "(quietly)", 60), 16, "parenthetical indent")
eq(render.indent_for("character", "MAYA", 60), 22, "character indent")
eq(render.indent_for("transition", "CUT TO:", 60), 53, "transition is right-aligned")
ok(render.indent_for("transition", "CUT TO:", 60) + #"CUT TO:" == 60, "transition ends at the right margin")
-- The `>` and `<` are concealed, so it is the visible text that gets centered.
eq(render.indent_for("centered", "> THE END <", 60), 26, "centered text is centered")
eq(render.indent_for("transition", "> SMASH CUT:", 60), 60 - #"SMASH CUT:", "forced transition ignores its marker")

eq(render.marker_ranges("scene_heading", ".THE ROOF"), { { 0, 1 } }, "forced scene heading marker")
eq(render.marker_ranges("character", "@McCLANE ^"), { { 0, 1 }, { 8, 10 } }, "forced cue and dual-dialogue caret")
eq(render.marker_ranges("centered", "> THE END <"), { { 0, 2 }, { 9, 11 } }, "centered markers")
eq(render.marker_ranges("action", "He waits."), {}, "no markers on plain action")

-- Element geometry, and how it scales when the page has to shrink.
eq({ render.geometry("dialogue", 60) }, { 10, 35 }, "dialogue geometry")
eq({ render.geometry("action", 60) }, { 0, 60 }, "action geometry")
eq({ render.geometry("dialogue", 30) }, { 5, 17 }, "dialogue geometry scales down")

-- Dialogue wraps at its own measure, and the padding carries the indent onto
-- the next screen row.
local speech = "I brought bribes. And an apology, and a theory about why the mayor called."
local wraps = render.wrap_marks(speech, 10, 35, 60)
ok(#wraps > 0, "long dialogue gets wrap marks", #wraps)
ok(wraps[1].col == #"I brought bribes. And an apology, ", "first break falls after a word", wraps[1].col)
eq(wraps[1].pad, 60 - (10 + #"I brought bribes. And an apology, ") + 10, "padding fills the row and indents the next")
eq(#render.wrap_marks("He waits.", 0, 60, 60), 0, "action is left to Neovim's own wrapping")

-- In a window wider than a page, the measure still rules: action breaks at 60
-- even though there are 90 columns of window, and the padding fills to 90.
local long_action = string.rep("word ", 30)
local wide = render.wrap_marks(long_action, 0, 60, 90)
ok(#wide > 0, "a wide window still breaks action at the page measure", #wide)
ok(wide[1].col <= 60 and wide[1].col > 50, "the break lands inside the measure", wide[1].col)
eq(wide[1].pad, 90 - wide[1].col, "padding reaches the real window edge")

vim.o.columns = 120
vim.o.lines = 40
local layout = zen.layout()
eq(layout.page.width, 60, "page is 60 columns wide")
eq(layout.page.col, 30, "page is centered")
eq(layout.degraded, false, "not degraded at 120 columns")

vim.o.columns = 50
layout = zen.layout()
ok(layout.page.width <= 50 and layout.page.width >= 32, "narrow terminal shrinks the page", layout.page.width)
eq(layout.degraded, true, "narrow terminal reports degraded")
vim.o.columns = 120

--------------------------------------------------------------------------- integration
section("integration")

vim.cmd.edit(root .. "/examples/sample.fountain")
vim.wait(200, function() return false end)
local buf = vim.api.nvim_get_current_buf()

eq(vim.bo[buf].filetype, "fountain", "filetype detected")
ok(vim.b[buf].fountain_studio_attached == true, "buffer attached")
ok(zen.is_open(), "zen page opened automatically")
eq(vim.api.nvim_win_get_width(zen.win()), 60, "zen window is one measure wide")

render.render(zen.win())
local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
ok(#marks > 0, "extmarks were placed", #marks)

local by_line = {}
for _, mark in ipairs(marks) do
  by_line[mark[2] + 1] = mark[4]
end

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local function lnum_of(text)
  for i, line in ipairs(lines) do
    if line == text then
      return i
    end
  end
end

local function indent_of(text)
  local mark = by_line[lnum_of(text)]
  if not mark or not mark.virt_text then
    return 0
  end
  return #mark.virt_text[1][1]
end

local function hl_of(text)
  local mark = by_line[lnum_of(text)]
  return mark and mark.hl_group or nil
end

eq(indent_of("MAYA"), 22, "MAYA is indented to the character margin")
eq(indent_of("(not looking up)"), 16, "parenthetical is indented")
eq(indent_of("Whatever it is, the answer is no."), 10, "dialogue is indented")
eq(indent_of("CUT TO:"), 53, "CUT TO: is right-aligned")
eq(indent_of("The buzzing stops. A beat. Then the office door opens."), 0, "action stays on the margin")
eq(hl_of("INT. NEWSROOM - NIGHT"), "FountainSceneHeading", "scene heading is highlighted")
eq(hl_of("MAYA"), "FountainCharacter", "character is highlighted")
eq(hl_of("CUT TO:"), "FountainTransition", "transition is highlighted")

-- Editing keeps the rendering in step.
vim.api.nvim_win_set_cursor(zen.win(), { lnum_of("MAYA"), 0 })
vim.cmd("normal! oI said no.")
vim.cmd("stopinsert")
vim.wait(100, function() return false end)
render.render(zen.win())
ok(#vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}) > 0, "still rendered after an edit")
vim.cmd("silent! undo")

-- Toggling off clears everything.
vim.cmd("FountainFormat")
eq(#vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}), 0, "FountainFormat off clears the marks")
vim.cmd("FountainFormat")
ok(#vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}) > 0, "FountainFormat on restores them")

-- Formatting is purely visual: the bytes on disk never change.
local original = table.concat(vim.fn.readfile(root .. "/examples/sample.fountain"), "\n")
local copy = vim.fn.tempname() .. ".fountain"
vim.cmd("write! " .. copy)
eq(table.concat(vim.fn.readfile(copy), "\n"), original, "writing the buffer leaves the file byte-identical")
vim.fn.delete(copy)

-- Typing keeps up, including inside a dialogue block.
vim.api.nvim_win_set_cursor(zen.win(), { lnum_of("I know."), 7 })
vim.cmd("normal! a And I have known for a while, which is the part that worries me most.")
vim.cmd("stopinsert")
vim.wait(50, function() return false end)
render.render(zen.win())
local edited = vim.api.nvim_buf_get_lines(buf, lnum_of("MAYA") - 1, -1, false)
ok(edited ~= nil, "buffer still readable after typing")
local speech_marks = 0
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
  if mark[4].virt_text and mark[3] > 0 then
    speech_marks = speech_marks + 1
  end
end
ok(speech_marks > 0, "long dialogue typed in insert mode gets wrap padding", speech_marks)
vim.cmd("silent! undo")

-- :q in the page quits the file rather than only leaving the layout -- but not
-- when that would throw away unsaved changes.
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "Note: dirty" })
vim.cmd("quit")
vim.wait(300, function() return false end)
ok(zen.is_open(), "an unsaved script stays on screen when :q is refused")
eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "Note: dirty", "the unsaved edit survives the refused :q")
vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
vim.bo[buf].modified = false

-- Opening something that is not a script hands it back to a normal window.
vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
vim.wait(50, function() return false end)
ok(not zen.is_open(), "opening a non-script buffer leaves the page")
vim.cmd.edit(root .. "/examples/sample.fountain")
vim.wait(200, function() return false end)

zen.close()
ok(not zen.is_open(), "zen closes cleanly")
vim.cmd("FountainZen")
ok(zen.is_open(), "FountainZen reopens the page")
zen.close()

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
vim.cmd(failed == 0 and "cq 0" or "cq 1")
