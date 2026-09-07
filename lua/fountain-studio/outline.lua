-- The scene outline that lives in the left margin.
--
-- Scenes in script order with how much page each one takes, measured the way a
-- production board measures it: in eighths of a page. The page count is an
-- estimate off the rendered line count, not a real pagination pass -- close
-- enough to see at a glance that a scene is running long.
local config = require("fountain-studio.config")
local layout = require("fountain-studio.layout")
local parser = require("fountain-studio.parser")
local script = require("fountain-studio.script")
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

--- Scene length the way a production board writes it: whole pages plus eighths.
function M.format_length(lines, page_lines)
  local cfg = config.get()
  page_lines = page_lines or cfg.page_lines
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
  -- The slug as it reads on screen: a writer who bolds their headings should
  -- see the heading in the outline, not the asterisks around it.
  local text = parser.plain(line)
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

--- The scenes of `bufnr`, with the slug rendered the way the outline shows it.
--- @return table[] entries, integer total page lines
function M.scan(bufnr)
  local analysis = script.analyse(bufnr)
  local entries = {}
  for index, entry in ipairs(analysis.scenes) do
    entries[index] = vim.tbl_extend("force", entry, {
      text = heading_text(entry.divider and "section" or "scene_heading", entry.text),
    })
  end
  return entries, analysis.total
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
function M.header(total, page)
  local cfg = config.get()
  if not cfg.outline.header then
    return ""
  end
  local right = M.format_length(total, cfg.page_lines)
  if page then
    right = "p" .. page .. " · " .. right
  end
  return "%#FountainOutlineHeader#SCENES%=" .. right .. " "
end

--- Build the display: one line per entry, plus the highlight ranges for it.
function M.build(entries, total, width)
  local cfg = config.get()
  local page_lines = cfg.page_lines
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
  return layout.margins().outline
end

--- The entry shown on display row `row`, if any.
function M.entry_at_row(row)
  return state.entries[state.rows[row]]
end

--- Put the cursor back where the writing happens.
function M.focus_page()
  local page = zen.win()
  if page and vim.api.nvim_win_is_valid(page) then
    pcall(vim.api.nvim_set_current_win, page)
  end
end

--- Send the page to the scene on `row` of the outline, defaulting to the row
--- the cursor -- or the click -- landed on, and hand focus back to the page.
function M.jump(row)
  if not M.is_open() or not state.source or not vim.api.nvim_buf_is_valid(state.source) then
    return
  end
  row = row or vim.api.nvim_win_get_cursor(state.win)[1]
  local entry = state.entries[state.rows[row]]
  if not entry then
    return M.focus_page()
  end

  local page = zen.win()
  if not page or not vim.api.nvim_win_is_valid(page) then
    return
  end

  local lnum = math.min(entry.lnum, vim.api.nvim_buf_line_count(state.source))
  pcall(vim.api.nvim_win_set_cursor, page, { lnum, 0 })
  vim.api.nvim_win_call(page, function()
    vim.cmd("normal! zz")
  end)
  M.focus_page()
  M.mark_current(lnum)
end

local function ensure_buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].filetype = "fountain_outline"
  vim.bo[state.buf].modifiable = false

  -- A click lands the cursor on the row first, so the release does the work.
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true })
  end
  map("<LeftRelease>", function()
    M.jump()
  end)
  map("<2-LeftMouse>", function()
    M.jump()
  end)
  map("<CR>", function()
    M.jump()
  end)
  map("<Esc>", function()
    M.focus_page()
  end)
  map("q", function()
    M.focus_page()
  end)

  return state.buf
end

--- Refresh the header, which reports the page the cursor is on alongside the
--- running length of the script.
function M.set_header(lnum)
  if not M.is_open() or not state.source or not vim.api.nvim_buf_is_valid(state.source) then
    return
  end
  local page = script.page_of(script.analyse(state.source, { stale_ok = true }), lnum or 1)
  pcall(
    vim.api.nvim_set_option_value,
    "winbar",
    M.header(M.total or 0, page),
    { win = state.win, scope = "local" }
  )
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
  M.total = total
  M.set_header(vim.api.nvim_get_current_buf() == state.source and vim.api.nvim_win_get_cursor(0)[1] or 1)

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

local function schedule_refresh(delay)  -- luacheck: ignore
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
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      M.mark_current(lnum)
      M.set_header(lnum)
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
