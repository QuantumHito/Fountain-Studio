-- Visual formatting of a Fountain buffer.
--
-- Nothing here touches the text. Indentation is drawn with inline virtual text
-- at column 0, so the file on disk stays a plain, unindented .fountain file
-- while the screen shows a page.
local config = require("fountain-studio.config")
local parser = require("fountain-studio.parser")

local M = {}

M.ns = vim.api.nvim_create_namespace("fountain-studio")

local HL = {
  scene_heading = "FountainSceneHeading",
  character = "FountainCharacter",
  parenthetical = "FountainParenthetical",
  transition = "FountainTransition",
  centered = "FountainCentered",
  section = "FountainSection",
  synopsis = "FountainSynopsis",
  lyrics = "FountainLyrics",
  title_page = "FountainTitlePage",
  page_break = "FountainPageBreak",
}

--- The measure actually available in `win`: the standard page width, unless the
--- window is too narrow to hold it.
--- @return integer width, boolean degraded
function M.measure(win)
  local cfg = config.get()
  local available = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or vim.o.columns
  if available >= cfg.width then
    return cfg.width, false
  end
  -- Too narrow for a real page: use every column there is and say so.
  return math.max(1, available), true
end

--- Byte ranges of the Fountain markers on `line`: the forced-element prefix and
--- the dual-dialogue caret. These are syntax, not text, so they are concealed
--- rather than counted when placing the line.
--- @return table[] { { 0-indexed start, end } }
function M.marker_ranges(kind, line)
  local ranges = {}
  local function add(pattern)
    local s, e = line:find(pattern)
    if s then
      ranges[#ranges + 1] = { s - 1, e }
    end
  end

  if kind == "scene_heading" and line:sub(1, 1) == "." and line:sub(2, 2) ~= "." then
    add("^%.")
  elseif kind == "action" and line:sub(1, 1) == "!" then
    add("^!")
  elseif kind == "character" and line:sub(1, 1) == "@" then
    add("^@")
  elseif kind == "lyrics" and line:sub(1, 1) == "~" then
    add("^~%s?")
  elseif kind == "transition" and line:sub(1, 1) == ">" then
    add("^>%s*")
  elseif kind == "centered" then
    add("^>%s*")
    add("%s*<$")
  end

  if kind == "character" then
    add("%s*%^%s*$")
  end

  return ranges
end

--- Display width of `line` once everything hidden from the reader is taken off:
--- the structural markers this plugin conceals, and the emphasis delimiters the
--- syntax file conceals whenever 'conceallevel' is on. Right-aligned elements
--- are placed against this, so a bolded transition still lands on the margin.
function M.visible_width(kind, line)
  local cfg = config.get()
  local text = line
  local conceallevel = cfg.winopts and cfg.winopts.conceallevel
  if conceallevel == nil or conceallevel > 0 then
    text = parser.strip_markup(text)
  end

  local width = vim.fn.strdisplaywidth(text)
  if not cfg.conceal_markers then
    return width
  end
  for _, range in ipairs(M.marker_ranges(kind, line)) do
    width = width - vim.fn.strdisplaywidth(line:sub(range[1] + 1, range[2]))
  end
  return math.max(0, width)
end

--- Indent and measure for an element, in columns, scaled down if the window is
--- narrower than a full page.
--- @return integer indent, integer measure
function M.geometry(kind, width)
  local cfg = config.get()
  local indent = cfg.indents[kind] or 0
  local measure = cfg.measures[kind] or cfg.width

  if width < cfg.width then
    local scale = width / cfg.width
    indent = math.floor(indent * scale)
    measure = math.floor(measure * scale)
  end

  indent = math.max(0, math.min(indent, math.max(0, width - 1)))
  measure = math.max(1, math.min(measure, width - indent))
  return indent, measure
end

--- Leading blank columns to draw for `line`, given its element type.
---
--- Right-aligned and centered elements are placed against the width the reader
--- sees, but Neovim breaks lines on the buffer text: a concealed character
--- still holds its place in the wrap calculation. So the indent is also kept
--- small enough that the *raw* line fits the window -- otherwise a bolded
--- `**CUT TO:**` would be pushed flush right and then wrap onto a second row.
--- `win_width` is where that edge is, and defaults to the page measure.
function M.indent_for(kind, line, width, win_width)
  win_width = win_width or width
  if kind == "transition" or kind == "centered" then
    local indent
    if kind == "transition" then
      indent = width - M.visible_width(kind, line)
    else
      indent = math.floor((width - M.visible_width(kind, line)) / 2)
    end
    local raw = vim.fn.strdisplaywidth(line)
    return math.max(0, math.min(indent, win_width - raw))
  end
  local indent = M.geometry(kind, width)
  return indent
end

--- Words of `line` as { start = byte index, word = ..., sep = trailing spaces }.
local function words(line)
  local out, i = {}, 1
  while true do
    local ws, we = line:find("%S+", i)
    if not ws then
      return out
    end
    local _, se = line:find("^%s*", we + 1)
    out[#out + 1] = { start = ws, word = line:sub(ws, we), sep = line:sub(we + 1, se) }
    i = se + 1
  end
end

--- Where to break `line` so it wraps at its own measure rather than at the
--- window edge, and how much padding to insert there.
---
--- Neovim wraps inline virtual text like ordinary text, so padding that runs
--- past the right edge of the window spills onto the next screen row: the tail
--- of that padding becomes the indent of the wrapped line. `win_width` is where
--- that edge is, which is not the page measure when the script is being edited
--- in an ordinary, wider window.
---
--- @return table[] { { col = byte index, pad = columns } }
function M.wrap_marks(line, indent, measure, win_width)
  local marks = {}
  if measure >= win_width - indent then
    return marks -- the element already wraps at the window edge; let Neovim do it
  end

  local used = 0
  for _, token in ipairs(words(line)) do
    local w = vim.fn.strdisplaywidth(token.word)
    if used > 0 and used + w > measure then
      local pad = math.max(0, win_width - (indent + used)) + indent
      if pad > 0 then
        marks[#marks + 1] = { col = token.start - 1, pad = pad }
      end
      used = w + vim.fn.strdisplaywidth(token.sep)
    else
      used = used + w + vim.fn.strdisplaywidth(token.sep)
    end
  end
  return marks
end

function M.enabled(bufnr)
  local flag = vim.b[bufnr].fountain_studio_format
  if flag == nil then
    return true
  end
  return flag
end

--- Redraw the visible region of `win`.
function M.render(win)
  win = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].fountain_studio_attached then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  if not M.enabled(bufnr) then
    return
  end

  local cfg = config.get()
  local total = vim.api.nvim_buf_line_count(bufnr)
  local top = math.max(1, vim.fn.line("w0", win) - cfg.overscan)
  local bot = math.min(total, vim.fn.line("w$", win) + cfg.overscan)
  -- Two different widths: the page measure everything is placed against, and
  -- the real window edge, which is where Neovim actually wraps.
  local width = M.measure(win)
  local win_width = vim.api.nvim_win_get_width(win)
  local wrap = vim.api.nvim_get_option_value("wrap", { win = win, scope = "local" })

  -- Fetch a window of lines, then walk back to the nearest blank line so the
  -- parser starts on a structural boundary. One line past `bot` is fetched
  -- because Character cues are defined by the line that follows them.
  local from = math.max(1, top - cfg.lookback)
  local lines = vim.api.nvim_buf_get_lines(bufnr, from - 1, math.min(total, bot + 1), false)

  local start = top - from + 1
  while start > 1 and not parser.is_blank(lines[start - 1]) do
    start = start - 1
  end

  local base = from + start - 1 -- buffer line number of slice[1]
  local slice = vim.list_slice(lines, start, #lines)
  local types = parser.scan(slice, { at_bof = base == 1, cfg = cfg })

  for i, line in ipairs(slice) do
    local lnum = base + i - 1
    local kind = types[i]
    if lnum >= top and lnum <= bot and kind ~= "blank" then
      local opts = { priority = 200, right_gravity = false }
      local applied = false
      local indent = 0

      if cfg.align then
        indent = M.indent_for(kind, line, width, win_width)
        if indent > 0 then
          opts.virt_text = { { string.rep(" ", indent), "FountainStudioIndent" } }
          opts.virt_text_pos = "inline"
          applied = true
        end
      end

      if cfg.highlight and HL[kind] then
        opts.end_row = lnum - 1
        opts.end_col = #line
        opts.hl_group = HL[kind]
        opts.hl_mode = "combine"
        applied = true
      end

      if applied then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, opts)
      end

      if cfg.conceal_markers then
        for _, range in ipairs(M.marker_ranges(kind, line)) do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, range[1], {
            end_row = lnum - 1,
            end_col = range[2],
            conceal = "",
            priority = 200,
          })
        end
      end

      if cfg.align and cfg.wrap_to_measure and wrap and kind ~= "transition" and kind ~= "centered" then
        local _, measure = M.geometry(kind, width)
        for _, mark in ipairs(M.wrap_marks(line, indent, measure, win_width)) do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, mark.col, {
            virt_text = { { string.rep(" ", mark.pad), "FountainStudioIndent" } },
            virt_text_pos = "inline",
            right_gravity = false,
            priority = 200,
          })
        end
      end
    end
  end
end

--- Redraw every window currently showing `bufnr`.
function M.render_buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      M.render(win)
    end
  end
end

function M.clear(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

return M
