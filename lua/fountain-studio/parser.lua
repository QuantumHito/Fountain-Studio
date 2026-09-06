-- Fountain element classification.
--
-- The parser is deliberately line-at-a-time and re-syncable: every blank line
-- is a structural boundary, so the renderer can start scanning at the blank
-- line above the viewport instead of parsing the whole script on every
-- keystroke.
local M = {}

local SCENE_PREFIXES = { "INT./EXT", "INT/EXT", "I/E", "INT", "EXT", "EST" }

function M.is_blank(line)
  return line == nil or line:match("^%s*$") ~= nil
end

local function trim(line)
  return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Uppercase in the Fountain sense: contains a letter and no lowercase ones.
local function is_upper(line)
  return line:match("%a") ~= nil and line == line:upper()
end

local function is_scene(line)
  local up = trim(line):upper()
  for _, prefix in ipairs(SCENE_PREFIXES) do
    if up:sub(1, #prefix) == prefix then
      local next_char = up:sub(#prefix + 1, #prefix + 1)
      if next_char == "" or next_char == "." or next_char == " " then
        return true
      end
    end
  end
  return false
end

local function is_transition(line, cfg)
  local up = trim(line):upper()
  if not is_upper(line) then
    return false
  end
  if up:match("TO:$") then
    return true
  end
  for _, pattern in ipairs((cfg and cfg.transition_patterns) or {}) do
    if up:match(pattern) then
      return true
    end
  end
  return false
end

-- A Character cue is an uppercase line preceded by a blank line and followed by
-- a non-blank one. A trailing `^` marks dual dialogue and a trailing
-- parenthetical extension -- (V.O.), (CONT'D) -- is part of the cue.
local function is_character(line)
  local text = trim(line):gsub("%^%s*$", "")
  local without_extension = text:gsub("%b()%s*$", "")
  if without_extension:match("^%s*$") then
    return false
  end
  return is_upper(without_extension)
end

local function looks_like_title_key(line)
  return line:match("^%s*[%a][%a%s]*:") ~= nil
end

--- Classify a contiguous run of lines.
---
--- `lines[1]` must sit on a structural boundary: either the first line of the
--- buffer, or a line whose predecessor is blank.
---
--- @param lines string[]
--- @param opts table|nil { at_bof: boolean, cfg: table }
--- @return string[] one element type per input line
function M.scan(lines, opts)
  opts = opts or {}
  local cfg = opts.cfg
  local types = {}
  local in_dialogue = false
  local in_title_page = opts.at_bof and lines[1] ~= nil and looks_like_title_key(lines[1])

  for i, raw in ipairs(lines) do
    local line = raw:gsub("%s+$", "")
    local kind

    if in_title_page then
      if M.is_blank(line) then
        in_title_page, kind = false, "blank"
      else
        kind = "title_page"
      end
    elseif M.is_blank(line) then
      in_dialogue, kind = false, "blank"
    elseif in_dialogue then
      if trim(line):match("^%(.*%)$") then
        kind = "parenthetical"
      elseif line:sub(1, 1) == "~" then
        kind = "lyrics"
      else
        kind = "dialogue"
      end
    else
      local first = line:sub(1, 1)
      local prev_blank = i == 1 or M.is_blank(lines[i - 1])
      local next_blank = M.is_blank(lines[i + 1])

      if line:match("^===+%s*$") then
        kind = "page_break"
      elseif first == "." and line:sub(2, 2) ~= "." then
        kind = "scene_heading"
      elseif first == "!" then
        kind = "action"
      elseif first == "@" then
        kind, in_dialogue = "character", true
      elseif first == ">" then
        kind = line:match("<%s*$") and "centered" or "transition"
      elseif first == "#" then
        kind = "section"
      elseif first == "=" then
        kind = "synopsis"
      elseif first == "~" then
        kind = "lyrics"
      elseif prev_blank and is_scene(line) then
        kind = "scene_heading"
      elseif prev_blank and next_blank and is_transition(line, cfg) then
        kind = "transition"
      elseif prev_blank and not next_blank and is_character(line) then
        kind, in_dialogue = "character", true
      else
        kind = "action"
      end
    end

    types[i] = kind
  end

  return types
end

--- Classify a single buffer line, re-syncing from the blank line above it.
--- Convenience for commands and tests; the renderer scans in bulk instead.
function M.classify_line(bufnr, lnum, cfg)
  local lookback = (cfg and cfg.lookback) or 200
  local from = math.max(1, lnum - lookback)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, from - 1, math.min(total, lnum + 1), false)

  local start = lnum - from + 1
  while start > 1 and not M.is_blank(lines[start - 1]) do
    start = start - 1
  end

  local slice = vim.list_slice(lines, start, #lines)
  local types = M.scan(slice, { at_bof = (from + start - 1) == 1, cfg = cfg })
  return types[lnum - (from + start - 1) + 1]
end

return M
