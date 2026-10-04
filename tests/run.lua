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

local skipped = 0
local function skip(name, why)
  skipped = skipped + 1
  io.write(("  skip  %s  -- %s\n"):format(name, why))
end

local function section(title)
  io.write("\n" .. title .. "\n")
end

vim.cmd("filetype plugin indent on")
vim.cmd("syntax on")

local fountain = require("fountain-studio")
fountain.setup({})

local export = require("fountain-studio.export")
local inspector = require("fountain-studio.inspector")
local outline = require("fountain-studio.outline")
local ruler = require("fountain-studio.ruler")
local script = require("fountain-studio.script")
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

-- Emphasis is markup, not part of the element: a writer who bolds their slug
-- lines is still writing scene headings.
eq(kinds("\n**INT. NEWSROOM - NIGHT**\n\nHe waits.", false),
  { "blank", "scene_heading", "blank", "action" }, "bolded scene heading")
eq(kinds("\n**INT. NEWSROOM - NIGHT**\nHe waits.", false),
  { "blank", "scene_heading", "action" }, "bolded heading with action right under it")
eq(kinds("\n*EXT. GARAGE - DAY*\n\n", false),
  { "blank", "scene_heading", "blank", "blank" }, "italicised scene heading")
eq(kinds("\n***INT. HOUSE - DAY***\n\n", false),
  { "blank", "scene_heading", "blank", "blank" }, "bold-italic scene heading")
eq(kinds("\n**CUT TO:**\n\n", false), { "blank", "transition", "blank", "blank" }, "bolded transition")
eq(kinds("\n**MAYA**\nGo home.\n", false), { "blank", "character", "dialogue", "blank" }, "bolded character cue")

-- Secondary slug lines mark a jump inside a scene: not a new scene, and not a
-- character cue for the action underneath them.
eq(kinds("\nMOMENTS LATER\n\nShe waits.", false),
  { "blank", "mini_slug", "blank", "action" }, "a mini-slug on its own")
eq(kinds("\nMOMENTS LATER\nShe waits.", false),
  { "blank", "mini_slug", "action" }, "action under a mini-slug stays action")
eq(kinds("\n.MOMENTS LATER\n\n", false),
  { "blank", "mini_slug", "blank", "blank" }, "a forced mini-slug is still a mini-slug")
eq(kinds("\n**MOMENTS LATER**\n\n", false),
  { "blank", "mini_slug", "blank", "blank" }, "a bolded mini-slug is still a mini-slug")
eq(kinds("\nBACK TO SCENE\nHe turns.", false),
  { "blank", "mini_slug", "action" }, "BACK TO SCENE is a mini-slug")
eq(kinds("\nEXT. GARAGE - CONTINUOUS\n\n", false),
  { "blank", "scene_heading", "blank", "blank" }, "a slug ending in CONTINUOUS is still a scene")
eq(kinds("\nMAYA\nGo home.\n", false),
  { "blank", "character", "dialogue", "blank" }, "an ordinary cue is untouched by the mini-slug rule")

eq(parser.strip_markup("**INT. HOUSE**"), "INT. HOUSE", "bold markers come off")
eq(parser.strip_markup("*a* and **b** and ***c***"), "a and b and c", "every emphasis form comes off")
eq(parser.strip_markup("_THE END_"), "THE END", "a wrapped underline comes off")
eq(parser.strip_markup("call some_var_name here"), "call some_var_name here", "snake_case is left alone")
eq(parser.plain("  **INT. HOUSE - DAY**  "), "INT. HOUSE - DAY", "plain() trims and unwraps")
eq(parser.plain("**INT. HOUSE"), "INT. HOUSE", "a half-typed marker still classifies")

--------------------------------------------------------------------------- geometry
-- The geometry below was read off afterwriting's own PDFs -- Courier 12pt at
-- 7.2pt a character -- rather than taken from a style guide: both profiles put
-- 55 rows on a page and indent the cue 20 and the parenthetical 15, and the
-- action measure is the only thing the paper changes.
eq(config.get().page_lines, 55, "55 rows to a page")
eq(config.profiles.usletter.width, 60, "US Letter gives a 60-column measure")
eq(config.profiles.a4.width, 55, "A4 gives 55")

config.setup({ profile = "a4" })
eq(config.get().width, 55, "the profile sets the measure")
config.setup({ profile = "a4", width = 58 })
eq(config.get().width, 58, "an explicit width still wins")
config.setup({})
eq(config.get().width, 60, "and the default is US Letter")

section("geometry")

eq(render.indent_for("action", "He waits.", 60), 0, "action sits on the margin")
eq(render.indent_for("dialogue", "Go home.", 60), 10, "dialogue indent")
eq(render.indent_for("parenthetical", "(quietly)", 60), 15, "parenthetical indent")
eq(render.indent_for("character", "MAYA", 60), 20, "character indent")
eq(render.indent_for("transition", "CUT TO:", 60), 53, "transition is right-aligned")
ok(render.indent_for("transition", "CUT TO:", 60) + #"CUT TO:" == 60, "transition ends at the right margin")
-- The `>` and `<` are concealed, so it is the visible text that gets centered.
eq(render.indent_for("centered", "> THE END <", 60), 26, "centered text is centered")
eq(render.indent_for("transition", "> SMASH CUT:", 60, 80), 60 - #"SMASH CUT:", "forced transition ignores its marker")
eq(render.indent_for("transition", "> SMASH CUT:", 60), 60 - #"> SMASH CUT:", "a concealed marker still holds its place in the wrap")

-- Concealed emphasis is not on screen, so it does not count towards placement.
eq(render.visible_width("transition", "**CUT TO:**"), #"CUT TO:", "bold markers do not count towards width")
-- Concealed characters still hold their place when Neovim breaks lines, so a
-- bolded transition is placed by its raw width: as far right as it can go
-- without wrapping onto a second row.
eq(render.indent_for("transition", "**CUT TO:**", 60), 60 - #"**CUT TO:**", "a bolded transition stays on one row")
eq(render.indent_for("transition", "**CUT TO:**", 60, 80), 60 - #"CUT TO:", "given room, it still lands on the margin")

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

--------------------------------------------------------------------------- outline
section("outline")

-- Scene length the way a production board writes it: eighths of a page.
eq(outline.format_length(55, 55), "1", "a full page")
eq(outline.format_length(110, 55), "2", "two pages")
eq(outline.format_length(27, 55), "4/8", "half a page")
eq(outline.format_length(69, 55), "1 2/8", "a page and a bit")
eq(outline.format_length(1, 55), "1/8", "anything at all is at least an eighth")

--------------------------------------------------------------------------- script analysis
section("script analysis")

local study = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(study, 0, -1, false, {
  "INT. NEWSROOM - NIGHT",                        -- 1
  "",
  "= Maya decides to run it anyway.",             -- 3
  "",
  "She types. [[check the timeline]]",            -- 5
  "",
  "MAYA (V.O.)",                                  -- 7
  "Whatever it is, the answer is no.",            -- 8
  "",
  "DANNY",                                        -- 10
  "I brought bribes.",                            -- 11
  "",
  "[[a note that runs",                           -- 13
  "across two lines]]",
  "",
  "EXT. GARAGE - DAY",                            -- 16
  "",
  "MAYA",                                         -- 18
  "Probably.",                                    -- 19
})
local study_analysis = script.analyse(study)

eq(#study_analysis.scenes, 2, "both scenes are found")
eq(study_analysis.scenes[1].synopsis, { "Maya decides to run it anyway." }, "the synopsis belongs to its scene")
eq(#study_analysis.scenes[1].notes, 2, "both notes fall in the first scene")
eq(study_analysis.notes[1].text, "check the timeline", "a note's text is extracted")
eq(study_analysis.notes[1].lnum, 5, "a note knows its line")
eq(study_analysis.notes[1].col, 12, "a note knows its column, so it can sit beside itself")
eq(study_analysis.notes[2].text, "a note that runs across two lines", "a note can span lines")
eq(study_analysis.notes[2].lnum, 13, "a spanning note is anchored where it opens")

eq(script.character_name("MAYA (V.O.)"), "MAYA", "an extension is not part of the name")
eq(script.character_name("@McCLANE ^"), "McCLANE", "nor is a cue marker or a dual-dialogue caret")
eq(script.character_name("**DANNY**"), "DANNY", "nor is emphasis")
eq(study_analysis.characters["MAYA"].speeches, 2, "speeches are counted per character")
eq(study_analysis.characters["MAYA"].last_lnum, 18, "and where they last spoke")
eq(study_analysis.scenes[1].cast["DANNY"], 1, "the scene cast counts dialogue lines")
ok(study_analysis.scenes[2].cast["DANNY"] == nil, "a character absent from a scene is not in its cast")

-- Scene lengths have to account for the whole script, or the outline's numbers
-- and the ruler's page marks tell different stories.
local accounted, first_slug = 0, nil
for _, entry in ipairs(study_analysis.scenes) do
  if not entry.divider then
    accounted = accounted + entry.lines
    first_slug = first_slug or entry.lnum
  end
end
eq(
  accounted + (study_analysis.cumulative[first_slug] or 0),
  study_analysis.total,
  "every page line belongs either to a scene or to the matter above the first slug"
)

-- What does and does not take up room on a printed page. Each of these was
-- checked against afterwriting: a synopsis, a section, a note and a boneyard
-- all leave its PDF byte-identical, a run of blank lines prints as a single
-- separator, and `===` starts a new page.
local function slots(lines)
  local probe = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(probe, 0, -1, false, lines)
  local total = script.analyse(probe).total
  vim.api.nvim_buf_delete(probe, { force = true })
  return total
end

local plain = slots({ "INT. ROOM - DAY", "", "She waits." })
eq(slots({ "INT. ROOM - DAY", "", "= A synopsis.", "", "She waits." }), plain, "a synopsis takes no page space")
eq(slots({ "# ACT ONE", "", "INT. ROOM - DAY", "", "She waits." }), plain, "nor does a section")
eq(slots({ "INT. ROOM - DAY", "", "[[a note]]", "", "She waits." }), plain, "nor does a note on its own line")
eq(slots({ "INT. ROOM - DAY", "", "She waits. [[a note]]" }), plain, "nor a note at the end of a line")
eq(slots({ "Title: X", "Author: Y", "", "INT. ROOM - DAY", "", "She waits." }), plain,
  "nor the title block, which prints on a page of its own")
eq(slots({ "INT. ROOM - DAY", "", "", "", "", "She waits." }), plain, "a run of blank lines is one separator")

local broken = slots({ "INT. A - DAY", "", "One.", "", "===", "", "INT. B - DAY", "", "Two." })
ok(broken > config.get().page_lines, "=== sends what follows to the next page", broken)
eq(
  script.page_of(script.analyse((function()
    local probe = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(probe, 0, -1, false,
      { "INT. A - DAY", "", "One.", "", "===", "", "INT. B - DAY", "", "Two." })
    return probe
  end)()), 7),
  2,
  "and the scene after it opens page 2"
)

eq(script.page_of(study_analysis, 1), 1, "the script opens on page 1")
eq(select(1, script.scene_at(study_analysis, 11)).lnum, 1, "a line belongs to the scene above it")
eq(select(1, script.scene_at(study_analysis, 19)).lnum, 16, "and to the next one after that")

-- The walk is shared, so it is only redone when the buffer changes.
ok(script.analyse(study) == study_analysis, "an unchanged buffer reuses its analysis")
vim.api.nvim_buf_set_lines(study, 0, 0, false, { "Title: Study", "" })
ok(script.analyse(study) ~= study_analysis, "an edit invalidates it")
vim.api.nvim_buf_delete(study, { force = true })

--------------------------------------------------------------------------- margins
section("ruler and inspector")

eq(ruler.mark(1, 5), "─── 1", "a page mark is a rule and a number")
eq(ruler.mark(12, 5), "── 12", "wider numbers take the rule's room")

eq(inspector.wrap("one two three", 7), { "one two", "three" }, "text wraps on spaces")
eq(inspector.wrap("supercalifragilistic", 8), { "supercal", "ifragili", "stic" }, "a long word is broken")
eq(inspector.wrap("", 10), {}, "nothing wraps to nothing")

-- Panels are dropped, not squeezed, as the terminal narrows.
local columns = vim.o.columns
local function panels(width)
  vim.o.columns = width
  local margins = require("fountain-studio.layout").margins()
  return {
    ruler = margins.ruler ~= nil,
    outline = margins.outline ~= nil,
    inspector = margins.inspector ~= nil,
  }
end
eq(panels(132), { ruler = true, outline = true, inspector = true }, "a wide terminal carries all three")
eq(panels(100).ruler, false, "the ruler gives up its columns before the outline does")
eq(panels(100).outline, true, "the outline survives at 100 columns")
eq(panels(80), { ruler = false, outline = false, inspector = false }, "an 80-column terminal is all page")
vim.o.columns = columns

--------------------------------------------------------------------------- export
section("export")

local script_path = "/tmp/a script.fountain"
eq(export.output_for(script_path), "/tmp/a script.pdf", "the PDF lands beside the script")
eq(export.output_for(script_path, "/tmp/named.pdf"), "/tmp/named.pdf", "an explicit name is taken as given")
eq(export.output_for(script_path, "/tmp"), "/tmp/a script.pdf", "a directory keeps the script's name")

eq(export.command(script_path, "/tmp/out.pdf"), {
  "afterwriting", "--source", script_path, "--pdf", "/tmp/out.pdf", "--overwrite",
  "--setting", "print_profile=usletter",
}, "the default command line, on the same paper as the editor")

config.setup({
  export = {
    overwrite = false,
    config_file = "/tmp/aw.json",
    settings = { "print_title_page=false", "double_space_between_scenes=true" },
  },
})
eq(export.command(script_path, "/tmp/out.pdf"), {
  "afterwriting", "--source", script_path, "--pdf", "/tmp/out.pdf",
  "--config", "/tmp/aw.json",
  "--setting", "print_title_page=false",
  "--setting", "double_space_between_scenes=true",
  "--setting", "print_profile=usletter",
}, "config, settings and overwrite are passed through")

-- A profile the writer chose themselves is not second-guessed.
config.setup({ export = { settings = { "print_profile=a4" } } })
local chosen = export.command(script_path, "/tmp/out.pdf")
eq(
  #vim.tbl_filter(function(item)
    return item:find("print_profile=") ~= nil
  end, chosen),
  1,
  "the paper is only named once"
)
ok(vim.tbl_contains(chosen, "print_profile=a4"), "and it is the one that was asked for")
config.setup({})

-- afterwriting exits 0 whatever happens, so failure is read out of its output.
eq(
  export.reason("'afterwriting command line interface\nwww: http://afterwriting.com\n\nLoading script: /nope\nCannot open script file /nope", false),
  "Cannot open script file /nope",
  "the complaint is picked out of the banner"
)
eq(export.reason("", false), "no PDF was written", "silence with no file is still a failure")
eq(export.reason("", true), "afterwriting did not report finishing", "a file without Done! is not success")

-- The real thing, where afterwriting is installed.
if export.available() then
  local work = vim.fn.tempname()
  vim.fn.mkdir(work, "p")
  local real = work .. "/a real script.fountain"
  vim.fn.writefile({ "Title: Real", "", "INT. ROOM - DAY", "", "She exports it.", "", "MAYA", "It worked." }, real)

  local messages = {}
  local notify = vim.notify
  vim.notify = function(message)
    messages[#messages + 1] = message
  end

  export.run({ bufnr = (function()
    local bufnr = vim.fn.bufadd(real)
    vim.fn.bufload(bufnr)
    return bufnr
  end)() })
  vim.wait(20000, function()
    return #messages > 0
  end)
  vim.notify = notify

  local pdf = work .. "/a real script.pdf"
  local stat = (vim.uv or vim.loop).fs_stat(pdf)
  ok(stat ~= nil and stat.size > 0, "afterwriting writes a PDF", messages[1])
  if stat then
    eq(table.concat(vim.fn.readfile(pdf, "b", 1), ""):sub(1, 5), "%PDF-", "and it is a PDF")
  end
  ok((messages[1] or ""):find("failed", 1, true) == nil, "and the run is reported as a success", messages[1])
  vim.fn.delete(work, "rf")
else
  skip("afterwriting writes a PDF", "afterwriting is not installed")
end

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

eq(indent_of("MAYA"), 20, "MAYA is indented to the character margin")
eq(indent_of("(not looking up)"), 15, "parenthetical is indented")
eq(indent_of("Whatever it is, the answer is no."), 10, "dialogue is indented")
eq(indent_of("CUT TO:"), 53, "CUT TO: is right-aligned")
eq(indent_of("The buzzing stops. A beat. Then the office door opens."), 0, "action stays on the margin")
eq(hl_of("INT. NEWSROOM - NIGHT"), "FountainSceneHeading", "scene heading is highlighted")
eq(hl_of("MAYA"), "FountainCharacter", "character is highlighted")
eq(hl_of("CUT TO:"), "FountainTransition", "transition is highlighted")

-- The virtual indentation must inherit the background of the window it is drawn
-- in. Pinning it to Normal made it show as a block of a different colour on any
-- theme where Normal and NormalFloat differ, Catppuccin among them.
local indent_hl = vim.api.nvim_get_hl(0, { name = "FountainStudioIndent" })
ok(
  indent_hl.fg == nil and indent_hl.bg == nil and indent_hl.link == nil,
  "the indent group carries no colour of its own",
  vim.inspect(indent_hl)
)
ok(
  (vim.api.nvim_get_option_value("winhighlight", { win = zen.win(), scope = "local" })):find("NormalFloat:Normal", 1, true) ~= nil,
  "the page window takes the editor's colours, not the float colours"
)

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

-- The outline follows the page into the left margin.
ok(outline.is_open(), "the outline opens with the page")
local outline_geometry = outline.layout()
local page_geometry = zen.layout().page
ok(
  outline_geometry.col + outline_geometry.width <= page_geometry.col,
  "the outline sits in the margin without touching the page",
  vim.inspect(outline_geometry)
)

local scenes, script_lines = outline.scan(buf)
local slugs = {}
for _, entry in ipairs(scenes) do
  slugs[#slugs + 1] = (entry.divider and "# " or "") .. entry.text
end
eq(slugs, {
  "# ACT ONE",
  "I. NEWSROOM - NIGHT",
  "E. PARKING GARAGE - CONTINUOUS",
  "THE ROOF - LATER",
}, "scenes in script order, sections as dividers, slugs abbreviated")

eq(scenes[2].number, 1, "the first scene is numbered 1")
eq(scenes[4].number, 3, "dividers do not take a scene number")
ok(scenes[2].lnum < scenes[3].lnum, "scene line numbers ascend")
ok(script_lines > 0, "the script has a measured length", script_lines)
for _, entry in ipairs(scenes) do
  if not entry.divider then
    ok(entry.lines > 0, "scene " .. entry.number .. " has a length", entry.lines)
  end
end

-- A script written with bolded slug lines lists its scenes like any other.
local bold_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bold_buf, 0, -1, false, {
  "**INT. NEWSROOM - NIGHT**",
  "",
  "She types.",
  "",
  "**EXT. PARKING GARAGE - CONTINUOUS**",
  "",
  "They walk.",
})
local bold_scenes = outline.scan(bold_buf)
eq(#bold_scenes, 2, "both bolded headings are found")
eq(bold_scenes[1].text, "I. NEWSROOM - NIGHT", "the outline shows the slug, not the asterisks")
eq(bold_scenes[2].number, 2, "bolded scenes are numbered in order")
vim.api.nvim_buf_delete(bold_buf, { force = true })

-- Every panel must listen for the same edits. TextChanged does not fire in
-- insert mode, so a panel without TextChangedI silently freezes for a whole
-- writing session -- which is what made the outline's scene lengths disagree
-- with the ruler's page marks.
local function change_events(group)
  local events = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = group, buffer = buf })) do
    events[autocmd.event] = true
  end
  return events
end
for _, group in ipairs({ "FountainStudioOutline", "FountainStudioRuler", "FountainStudioInspector" }) do
  local events = change_events(group)
  ok(events["TextChanged"], group .. " re-measures on an edit in normal mode")
  ok(events["TextChangedI"], group .. " re-measures while typing in insert mode")
  ok(events["CursorMoved"] and events["CursorMovedI"], group .. " follows the cursor in either mode")
end

-- A smoke check that the panel redraws at all after an edit: it reads what the
-- outline is showing rather than what a fresh scan would say. It is not what
-- catches the insert-mode gap -- the suite's earlier events can leave a
-- debounce pending that refreshes this anyway -- the event-list checks above
-- are, and they fail without TextChangedI.
local function outline_display()
  local out = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(outline.buf(), 0, -1, false)) do
    if line ~= "" then
      out[#out + 1] = vim.trim(line)
    end
  end
  return table.concat(out, " | ")
end

local grew = {}
for index = 1, 70 do
  grew[index] = "He keeps walking past the shuttered shops, number " .. index .. "."
end
local displayed_before = outline_display()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, grew)
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
vim.wait(2000, function()
  return outline_display() ~= displayed_before
end)
ok(
  outline_display() ~= displayed_before,
  "the outline redraws while you are still in insert mode",
  "still showing: " .. outline_display()
)
vim.api.nvim_buf_set_lines(buf, -71, -1, false, {})
vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
vim.wait(1000, function()
  return outline_display() == displayed_before
end)
vim.bo[buf].modified = false

-- The margins come up with the page.
ok(ruler.is_open(), "the ruler opens with the page")
ok(inspector.is_open(), "the inspector opens with the page")
eq(inspector.mode(), "scene", "the inspector starts on the scene panel")

-- The scene panel reports the scene the cursor is in.
local panel = inspector.scene_panel(script.analyse(buf), lnum_of("MAYA"), 28)
local panel_text = table.concat(panel, "\n")
ok(panel_text:find("NEWSROOM", 1, true) ~= nil, "the panel names the scene", panel_text)
ok(panel_text:find("IN THIS SCENE", 1, true) ~= nil, "and who is in it")
ok(panel_text:find("MAYA", 1, true) ~= nil, "and lists them by name")

inspector.set_mode("notes")
eq(inspector.mode(), "notes", "the inspector switches to notes")
inspector.set_mode("scene")

-- A mini-slug belongs to the scene it sits in, so it adds no outline entry.
local mini_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(mini_buf, 0, -1, false, {
  "INT. KITCHEN - DAY", "", "She waits.", "",
  "MOMENTS LATER", "", "She is still waiting.", "",
  ".LATER", "", "Still.",
})
local mini_scenes = outline.scan(mini_buf)
eq(#mini_scenes, 1, "mini-slugs do not split the scene")
eq(mini_scenes[1].text, "I. KITCHEN - DAY", "the scene is the one real slug")
vim.api.nvim_buf_delete(mini_buf, { force = true })

-- The margin panels keep their distance and never overlap. The outline's gap is
-- measured to whatever is next inwards -- the ruler, when it is showing.
local margins = require("fountain-studio.layout").margins()
local inward = margins.ruler and margins.ruler.col or margins.page.col
eq(inward - (outline_geometry.col + outline_geometry.width), config.get().outline.gap,
  "the configured gap sits between the outline and what is inside it")
ok(outline_geometry.col + outline_geometry.width < margins.page.col, "the outline does not touch the page")
if margins.ruler then
  eq(margins.page.col - (margins.ruler.col + margins.ruler.width), config.get().ruler.gap,
    "the ruler sits just outside the page")
end
if margins.inspector then
  eq(margins.inspector.col - (margins.page.col + margins.page.width), config.get().inspector.gap,
    "the inspector sits just outside the page on the other side")
end

-- Clicking a scene sends the page there and hands focus back.
local jump_target = outline.entry_at_row(3)
ok(jump_target ~= nil, "there is an entry to jump to")
outline.jump(3)
eq(vim.api.nvim_win_get_cursor(zen.win())[1], jump_target.lnum, "the page jumps to the scene")
eq(vim.api.nvim_get_current_win(), zen.win(), "focus goes back to the page")

-- A scene the cursor is inside gets marked, and the mark follows the cursor.
outline.mark_current(scenes[2].lnum)
local marked = vim.api.nvim_buf_get_extmarks(outline.buf(), outline.ns_current, 0, -1, {})
outline.mark_current(scenes[3].lnum)
local moved = vim.api.nvim_buf_get_extmarks(outline.buf(), outline.ns_current, 0, -1, {})
ok(#marked == 1, "the scene under the cursor is marked", vim.inspect(marked))
ok(#moved == 1 and moved[1][2] > marked[1][2], "the mark follows the cursor to the next scene",
  vim.inspect({ marked[1], moved[1] }))

-- Too narrow a margin means no outline rather than a squeezed one.
local columns = vim.o.columns
vim.o.columns = 70
eq(outline.layout(), nil, "a margin too narrow for the outline is left blank")
vim.o.columns = columns

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

io.write(("\n%d passed, %d failed%s\n"):format(passed, failed, skipped > 0 and (", " .. skipped .. " skipped") or ""))
vim.cmd(failed == 0 and "cq 0" or "cq 1")
