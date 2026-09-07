-- The scene outline that lives in the left margin.
--
-- Scenes in script order with how much page each one takes, measured the way a
-- production board measures it: in eighths of a page. The page count is an
-- estimate off the rendered line count, not a real pagination pass -- close
-- enough to see at a glance that a scene is running long.
local config = require("fountain-studio.config")
local parser = require("fountain-studio.parser")
local render = require("fountain-studio.render")
local zen = require("fountain-studio.zen")

local M = {}

M.ns = vim.api.nvim_create_namespace("fountain-studio-outline")
M.ns_current = vim.api.nvim_create_namespace("fountain-studio-outline-current")

local uv = vim.uv or vim.loop

local state = {
  win = nil,
  buf = nil,
  source = nil, -- the script buffer the outline is describing
  entries = {},
  rows = {},        -- display row (1-indexed) -> entry index
  scene_rows = {},  -- { row = display row, lnum = buffer line }, in script order
  current = nil,
  timer = nil,
  augroup = nil,
}

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- The outline's own window and scratch buffer, or nil when it is not up.
function M.win()
  return M.is_open() and state.win or nil
end

function M.buf()
  return (state.buf and vim.api.nvim_buf_is_valid(state.buf)) and state.buf or nil
end

--------------------------------------------------------------------- measuring

--- How many lines of a printed page `line` occupies, wrapped at its own measure.
local function page_lines_for(kind, line, width)
  if kind == "blank" then
    return 1
  end
  local _, measure = render.geometry(kind, width)
  local visible = render.visible_width(kind, line)
  return math.max(1, math.ceil(visible / math.max(1, measure)))
end

--- Scene length the way a production board writes it: whole pages plus eighths.
function M.format_length(lines, page_lines)
  local cfg = config.get()
  if cfg.outline.units == "decimal" then
    return ("%.1f"):format(lines / page_lines)
  end

  local eighths = math.max(1, math.floor(lines / page_lines * 8 + 0.5))
  local pages, rest = math.floor(eighths / 8), eighths % 8
  if pages == 0 then
    return rest .. "/8"
  elseif rest == 0 then
    return tostring(pages)
  end
  return pages .. " " .. rest .. "/8"
end

local function heading_text(kind, line)
  local cfg = config.get()
  local text = line:gsub("^%s+", ""):gsub("%s+$", "")
  if kind == "section" then
    return (text:gsub("^#+%s*", ""))
  end

  text = text:gsub("^%.", "") -- a forced heading's marker
  if cfg.outline.abbreviate then
    text = text
      :gsub("^INT%.?/EXT%.?%s*", "I/E ")
      :gsub("^I/E%s*", "I/E ")
      :gsub("^INT%.?%s+", "I. ")
      :gsub("^EXT%.?%s+", "E. ")
      :gsub("^EST%.?%s+", "EST ")
  end
  return text
end

--- Walk the whole script once, collecting scenes and their lengths.
function M.scan(bufnr)
  local cfg = config.get()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local types = parser.scan(lines, { at_bof = true, cfg = cfg })

  local entries, current, total, number = {}, nil, 0, 0

  for i, line in ipairs(lines) do
    local kind = types[i]
    local height = page_lines_for(kind, line, cfg.width)

    if kind == "scene_heading" then
      number = number + 1
      current = {
        lnum = i,
        number = number,
        text = heading_text(kind, line),
        lines = 0,
        start = total,
      }
      entries[#entries + 1] = current
    elseif kind == "section" and cfg.outline.sections then
      -- A divider, not a scene: no number, no length, and it does not take the
      -- following lines away from the scene they belong to.
      entries[#entries + 1] = { lnum = i, divider = true, text = heading_text(kind, line) }
    end

    if current then
      current.lines = current.lines + height
    end
    total = total + height
  end

  return entries, total
end

--------------------------------------------------------------------- rendering

local function truncate(text, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

--- The pinned header: the script's running length, in the winbar so that it
--- stays put while the list of scenes scrolls under it.
function M.header(total)
  local cfg = config.get()
  if not cfg.outline.header then
    return ""
  end
  return "%#FountainOutlineHeader#SCENES%=" .. M.format_length(total, cfg.outline.page_lines) .. " "
end

--- Build the display: one line per entry, plus the highlight ranges for it.
function M.build(entries, total, width)
  local cfg = config.get()
  local page_lines = cfg.outline.page_lines
  local display, highlights, rows = {}, {}, {}

  local function add(text, ranges, entry_index)
    display[#display + 1] = text
    highlights[#highlights + 1] = ranges or {}
    rows[#display] = entry_index
  end

  local scenes = 0
  for _, entry in ipairs(entries) do
    if not entry.divider then
      scenes = scenes + 1
    end
  end

  if scenes == 0 then
    add(truncate("(no scenes yet)", width), { { 0, -1, "FountainOutlineEmpty" } })
    return display, highlights, rows
  end

  local number_width = math.max(2, #tostring(scenes))
  local length_width = 0
  for _, entry in ipairs(entries) do
    if not entry.divider then
      entry.length = M.format_length(entry.lines, page_lines)
      length_width = math.max(length_width, #entry.length)
    end
  end
  local text_width = width - number_width - length_width - 2

  for index, entry in ipairs(entries) do
    if entry.divider then
      add(truncate(entry.text, width), { { 0, -1, "FountainOutlineSection" } }, index)
    else
      local number = ("%" .. number_width .. "d"):format(entry.number)
      local text = truncate(entry.text, text_width)
      local pad = math.max(1, text_width - vim.fn.strdisplaywidth(text) + 1)
      local line = number .. " " .. text .. string.rep(" ", pad) .. entry.length
      local text_start = #number + 1
      add(line, {
        { 0, #number, "FountainOutlineNumber" },
        { text_start, text_start + #text, "FountainOutlineHeading" },
        { #line - #entry.length, #line, "FountainOutlineLength" },
      }, index)
    end
  end

  return display, highlights, rows
end

--------------------------------------------------------------------- the window

function M.layout()
  local cfg = config.get()
  if not cfg.outline.enabled then
    return nil
  end

  local page = zen.layout().page
  local available = page.col - cfg.outline.gap
  if available < cfg.outline.min_width then
    return nil -- no margin to speak of; the page comes first
  end

  local width = math.min(cfg.outline.width, available)
  return {
    relative = "editor",
    width = width,
    height = page.height,
    row = page.row,
    col = math.max(0, page.col - cfg.outline.gap - width),
    style = "minimal",
    focusable = false,
    border = "none",
    zindex = 45, -- above the backdrop, below the page
  }
end

local function ensure_buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].filetype = "fountain_outline"
  vim.bo[state.buf].modifiable = false
  return state.buf
end

--- Mark the scene the cursor is currently sitting in.
function M.mark_current(lnum)
  if not M.is_open() then
    return
  end

  -- state.scene_rows is in script order, so the scene the cursor is in is the
  -- last one that starts at or above it.
  local row
  for _, scene in ipairs(state.scene_rows) do
    if scene.lnum > lnum then
      break
    end
    row = scene.row
  end

  if row == state.current then
    return
  end
  state.current = row

  vim.api.nvim_buf_clear_namespace(state.buf, M.ns_current, 0, -1)
  if not row then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, state.buf, M.ns_current, row - 1, 0, {
    line_hl_group = "FountainOutlineCurrent",
    priority = 250,
  })
  -- Keep it in view without stealing focus.
  pcall(vim.api.nvim_win_set_cursor, state.win, { row, 0 })
end

--- Re-read the script and redraw the outline.
function M.refresh()
  if not M.is_open() or not state.source or not vim.api.nvim_buf_is_valid(state.source) then
    return
  end

  local width = vim.api.nvim_win_get_width(state.win)
  local entries, total = M.scan(state.source)
  local display, highlights, rows = M.build(entries, total, width)
  pcall(vim.api.nvim_set_option_value, "winbar", M.header(total), { win = state.win, scope = "local" })

  state.entries, state.rows, state.current = entries, rows, nil
  state.scene_rows = {}
  for row, index in pairs(rows) do
    local entry = entries[index]
    if entry and not entry.divider then
      state.scene_rows[#state.scene_rows + 1] = { row = row, lnum = entry.lnum }
    end
  end
  table.sort(state.scene_rows, function(a, b)
    return a.lnum < b.lnum
  end)

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, display)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, M.ns, 0, -1)
  for row, ranges in ipairs(highlights) do
    for _, range in ipairs(ranges) do
      pcall(vim.api.nvim_buf_set_extmark, state.buf, M.ns, row - 1, range[1], {
        end_row = row - 1,
        end_col = range[2] == -1 and #display[row] or range[2],
        hl_group = range[3],
        priority = 200,
      })
    end
  end

  local cursor = 1
  if vim.api.nvim_get_current_buf() == state.source then
    cursor = vim.api.nvim_win_get_cursor(0)[1]
  end
  M.mark_current(cursor)
end

local function schedule_refresh(delay)
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  state.timer = uv.new_timer()
  state.timer:start(
    delay or 200,
    0,
    vim.schedule_wrap(function()
      if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
      end
      M.refresh()
    end)
  )
end

local function setup_autocmds()
  state.augroup = vim.api.nvim_create_augroup("FountainStudioOutline", { clear = true })

  -- Re-measuring walks the whole script, so it waits for a pause in typing.
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = state.augroup,
    buffer = state.source,
    callback = function()
      schedule_refresh()
    end,
  })

  -- Following the cursor is cheap and should feel immediate.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.augroup,
    buffer = state.source,
    callback = function()
      M.mark_current(vim.api.nvim_win_get_cursor(0)[1])
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = state.augroup,
    callback = function()
      M.resize()
    end,
  })
end

function M.open(source)
  if M.is_open() then
    return state.win
  end
  if not zen.is_open() then
    vim.notify("fountain: the outline needs the page (:FountainZen)", vim.log.levels.WARN)
    return nil
  end
  local geometry = M.layout()
  if not geometry then
    return nil
  end

  state.source = source or vim.api.nvim_get_current_buf()
  local buf = ensure_buffer()
  state.win = vim.api.nvim_open_win(buf, false, vim.tbl_extend("force", geometry, { noautocmd = true }))

  local cfg = config.get()
  if cfg.zen.winhighlight then
    pcall(vim.api.nvim_set_option_value, "winhighlight", cfg.zen.winhighlight, { win = state.win, scope = "local" })
  end
  pcall(vim.api.nvim_set_option_value, "wrap", false, { win = state.win, scope = "local" })
  pcall(vim.api.nvim_set_option_value, "fillchars", "eob: ", { win = state.win, scope = "local" })

  setup_autocmds()
  M.refresh()
  return state.win
end

function M.resize()
  if not M.is_open() then
    return
  end
  local geometry = M.layout()
  if not geometry then
    return M.close()
  end
  pcall(vim.api.nvim_win_set_config, state.win, geometry)
  M.refresh()
end

function M.close()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end

  local win = state.win
  state.win, state.source, state.entries, state.rows = nil, nil, {}, {}
  state.scene_rows, state.current = {}, nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

function M.toggle(source)
  if M.is_open() then
    M.close()
  else
    M.open(source)
  end
end

--- Follow the page: the outline exists only while the layout does.
function M.setup()
  local group = vim.api.nvim_create_augroup("FountainStudioOutlineLifecycle", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FountainStudioZenOpen",
    callback = function()
      if config.get().outline.enabled then
        vim.schedule(function()
          -- The page can be gone again by the time this runs.
          if zen.is_open() then
            M.open(vim.api.nvim_get_current_buf())
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FountainStudioZenClose",
    callback = function()
      M.close()
    end,
  })
end

return M
