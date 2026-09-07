-- One pass over the script, shared by everything in the margins.
--
-- The outline needs scenes and their lengths, the ruler needs where the page
-- breaks fall, and the inspector needs notes, synopses and who speaks. That is
-- the same walk three times, so it is done once and cached against the buffer's
-- changedtick.
local config = require("fountain-studio.config")
local parser = require("fountain-studio.parser")
local render = require("fountain-studio.render")

local M = {}

local cache = {}

--- A character's name as it should be counted: no cue marker, no extension,
--- no dual-dialogue caret, no emphasis.
function M.character_name(line)
  local text = parser.plain(line):gsub("^@", ""):gsub("%^%s*$", "")
  text = text:gsub("%b()", "")
  return vim.trim(text)
end

--- How many lines of a printed page a line occupies, wrapped at its measure.
local function page_lines_for(kind, line, width)
  if kind == "blank" then
    return 1
  end
  local _, measure = render.geometry(kind, width)
  return math.max(1, math.ceil(render.visible_width(kind, line) / math.max(1, measure)))
end

--- Pull `[[ ... ]]` notes out of a line, continuing one left open above it.
--- The column of the opening `[[` is kept so the notes column can sit beside
--- the row the note actually appears on, not the row its line starts on.
local function collect_notes(state, notes, lnum, line)
  local pos = 1
  while pos <= #line do
    if state.open then
      local close_start, close_end = line:find("%]%]", pos)
      if not close_start then
        state.text[#state.text + 1] = line:sub(pos)
        return
      end
      state.text[#state.text + 1] = line:sub(pos, close_start - 1)
      local text = vim.trim(table.concat(state.text, " "):gsub("%s+", " "))
      if text ~= "" then
        notes[#notes + 1] = { lnum = state.lnum, col = state.col, text = text }
      end
      state.open, state.text = false, {}
      pos = close_end + 1
    else
      local open_start, open_end = line:find("%[%[", pos)
      if not open_start then
        return
      end
      state.open, state.lnum, state.col, state.text = true, lnum, open_start, {}
      pos = open_end + 1
    end
  end
end

local function walk(bufnr)
  local cfg = config.get()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local types = parser.scan(lines, { at_bof = true, cfg = cfg })

  local result = {
    types = types,
    heights = {},
    cumulative = {}, -- page lines before this line
    total = 0,
    scenes = {},
    notes = {},
    speeches = {},
    characters = {},
    synopses = {},
    scene_count = 0,
    line_count = #lines,
  }

  local note_state = { open = false, text = {}, lnum = nil, col = 1 }
  local scene, speech, number = nil, nil, 0

  for i, line in ipairs(lines) do
    local kind = types[i]
    result.cumulative[i] = result.total
    local height = page_lines_for(kind, line, cfg.width)
    result.heights[i] = height
    result.total = result.total + height

    collect_notes(note_state, result.notes, i, line)

    if kind == "scene_heading" then
      number = number + 1
      scene = { lnum = i, number = number, text = line, lines = 0, start = result.cumulative[i] }
      result.scenes[#result.scenes + 1] = scene
    elseif kind == "section" and cfg.outline.sections then
      result.scenes[#result.scenes + 1] = { lnum = i, divider = true, text = line }
    elseif kind == "synopsis" then
      result.synopses[#result.synopses + 1] = { lnum = i, text = vim.trim((line:gsub("^%s*=+%s*", ""))) }
    end

    if kind == "character" then
      speech = { lnum = i, name = M.character_name(line), lines = 0 }
      result.speeches[#result.speeches + 1] = speech
      local who = result.characters[speech.name]
        or { name = speech.name, lines = 0, speeches = 0, first_lnum = i, last_lnum = i }
      who.speeches, who.last_lnum = who.speeches + 1, i
      result.characters[speech.name] = who
    elseif kind == "dialogue" or kind == "lyrics" then
      if speech then
        speech.lines = speech.lines + height
        result.characters[speech.name].lines = result.characters[speech.name].lines + height
      end
    elseif kind == "blank" then
      speech = nil
    end

    if scene then
      scene.lines = scene.lines + height
    end
  end

  result.scene_count = number

  -- Scene ranges, then everything that falls inside them.
  local scenes = result.scenes
  for index, entry in ipairs(scenes) do
    local following = scenes[index + 1]
    entry.stop = following and (following.lnum - 1) or result.line_count
    entry.notes, entry.synopsis, entry.cast = {}, {}, {}
  end

  local function scene_at(lnum)
    local found
    for _, entry in ipairs(scenes) do
      if entry.divider then
        -- a section heading is not a scene: it owns nothing
      elseif entry.lnum <= lnum then
        found = entry
      else
        break
      end
    end
    return found
  end

  for _, note in ipairs(result.notes) do
    local owner = scene_at(note.lnum)
    if owner then
      owner.notes[#owner.notes + 1] = note
    end
  end
  for _, synopsis in ipairs(result.synopses) do
    local owner = scene_at(synopsis.lnum)
    if owner then
      owner.synopsis[#owner.synopsis + 1] = synopsis.text
    end
  end
  for _, one in ipairs(result.speeches) do
    local owner = scene_at(one.lnum)
    if owner then
      owner.cast[one.name] = (owner.cast[one.name] or 0) + one.lines
    end
  end

  return result
end

--- The analysis for `bufnr`, reusing the last one while the buffer is unchanged.
---
--- `opts.stale_ok` accepts the previous analysis even after an edit. The walk
--- costs about 60 ms on a feature-and-a-half of script, which is far too much
--- to pay on every keystroke -- so the margins read stale while you type and a
--- debounced refresh brings them up to date once you stop. Nothing that has to
--- be exact, the page itself above all, reads from here.
function M.analyse(bufnr, opts)
  local cfg = config.get()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local hit = cache[bufnr]
  if hit and ((hit.changedtick == tick and hit.width == cfg.width) or (opts and opts.stale_ok)) then
    return hit
  end

  local result = walk(bufnr)
  result.changedtick, result.width = tick, cfg.width
  cache[bufnr] = result
  return result
end

function M.forget(bufnr)
  cache[bufnr] = nil
end

--- Which page a line falls on, counting from 1.
function M.page_of(analysis, lnum)
  local before = analysis.cumulative[lnum] or 0
  return math.floor(before / config.get().page_lines) + 1
end

--- The scene containing `lnum`, and its index in `analysis.scenes`.
function M.scene_at(analysis, lnum)
  local found, found_index
  for index, entry in ipairs(analysis.scenes) do
    if not entry.divider then
      if entry.lnum <= lnum then
        found, found_index = entry, index
      else
        break
      end
    end
  end
  return found, found_index
end

return M
