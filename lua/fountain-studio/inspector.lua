-- The right margin.
--
-- Two modes, because writing and reading a draft back want different things:
--
--   "scene"  the scene you are in -- its slug, synopsis, notes, who speaks in
--            it and how much, and when everyone in the script last spoke.
--   "notes"  nothing but notes, each one beside the line it belongs to, for
--            going through a draft and catching them.
local config = require("fountain-studio.config")
local layout = require("fountain-studio.layout")
local parser = require("fountain-studio.parser")
local outline = require("fountain-studio.outline")
local script = require("fountain-studio.script")
local util = require("fountain-studio.util")
local zen = require("fountain-studio.zen")

local M = {}

M.ns = vim.api.nvim_create_namespace("fountain-studio-inspector")

local state = { win = nil, buf = nil, source = nil, augroup = nil, mode = nil }

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.win()
  return M.is_open() and state.win or nil
end

function M.buf()
  return (state.buf and vim.api.nvim_buf_is_valid(state.buf)) and state.buf or nil
end

function M.mode()
  return state.mode or config.get().inspector.mode
end

function M.layout()
  return layout.margins().inspector
end

--------------------------------------------------------------------- text bits

--- Break `text` into lines no wider than `width`, on spaces where it can.
function M.wrap(text, width)
  local out, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      out[#out + 1] = line
      line = word
    end
    while #line > width do -- a single word longer than the column
      out[#out + 1] = line:sub(1, width)
      line = line:sub(width + 1)
    end
  end
  if line ~= "" then
    out[#out + 1] = line
  end
  return out
end

--- A row of "name .... value", with the value pushed to the right edge.
local function row(name, value, width)
  local room = width - #value - 1
  local label = #name > room and (name:sub(1, math.max(1, room - 1)) .. "…") or name
  local pad = math.max(1, width - #label - #value)
  return label .. string.rep(" ", pad) .. value
end

--------------------------------------------------------------------- scene mode

--- What the inspector shows for the scene the cursor is in.
--- @return string[] lines, table[] highlight ranges per line
function M.scene_panel(analysis, lnum, width)
  local cfg = config.get()
  local display, highlights = {}, {}

  local function add(text, group)
    display[#display + 1] = text
    highlights[#highlights + 1] = group
  end
  local function section(title)
    if #display > 0 then
      add("", nil)
    end
    add(title, "FountainInspectorHeader")
  end

  local scene = script.scene_at(analysis, lnum)
  if not scene then
    add("(no scene yet)", "FountainInspectorDim")
    return display, highlights
  end

  -- The slug as it reads on the page, not as it is typed.
  for _, line in ipairs(M.wrap((parser.plain(scene.text):gsub("^%.", "")), width)) do
    add(line, "FountainInspectorSlug")
  end
  add(outline.format_length(scene.lines, cfg.page_lines) .. " · page " .. script.page_of(analysis, scene.lnum),
    "FountainInspectorDim")

  if #scene.synopsis > 0 then
    section("SYNOPSIS")
    for _, text in ipairs(scene.synopsis) do
      for _, line in ipairs(M.wrap(text, width)) do
        add(line, "FountainInspectorText")
      end
    end
  end

  if #scene.notes > 0 then
    section("NOTES")
    for _, note in ipairs(scene.notes) do
      local wrapped = M.wrap(note.text, width - 2)
      for index, line in ipairs(wrapped) do
        add((index == 1 and "· " or "  ") .. line, "FountainInspectorNote")
      end
    end
  end

  if cfg.inspector.cast then
    local cast = {}
    for name, lines in pairs(scene.cast) do
      cast[#cast + 1] = { name = name, lines = lines }
    end
    table.sort(cast, function(a, b)
      if a.lines == b.lines then
        return a.name < b.name
      end
      return a.lines > b.lines
    end)
    if #cast > 0 then
      section("IN THIS SCENE")
      for _, who in ipairs(cast) do
        add(row(who.name, tostring(who.lines), width), "FountainInspectorCharacter")
      end
    end
  end

  if cfg.inspector.tracker then
    -- Everyone who has spoken by this point, most recent first, with how much
    -- page has gone by since -- so a character who has quietly dropped out of
    -- the script is visible.
    local spoken = {}
    for _, who in pairs(analysis.characters) do
      if who.first_lnum <= lnum then
        spoken[#spoken + 1] = who
      end
    end
    table.sort(spoken, function(a, b)
      return a.last_lnum > b.last_lnum
    end)

    if #spoken > 0 then
      section("LAST SPOKE")
      local here = analysis.cumulative[math.min(lnum, analysis.line_count)] or 0
      for index, who in ipairs(spoken) do
        if index > cfg.inspector.tracked then
          break
        end
        local gone = here - (analysis.cumulative[who.last_lnum] or 0)
        local since = (scene.lnum <= who.last_lnum) and "here"
          or outline.format_length(math.max(0, gone), cfg.page_lines)
        add(row(who.name, since, width), "FountainInspectorCharacter")
      end
    end
  end

  return display, highlights
end

--------------------------------------------------------------------- notes mode

--- Which screen row of the page window a buffer line is drawn on.
local function screen_row(page_win, lnum, col)
  local position = vim.fn.screenpos(page_win, lnum, col or 1)
  if position.row == 0 then
    return nil
  end
  return position.row - vim.api.nvim_win_get_position(page_win)[1]
end

--- A winbar occupies the first row of a window, pushing its buffer down one.
local function row_offset(win)
  local winbar = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
  return (winbar ~= nil and winbar ~= "") and 1 or 0
end

--- Notes laid out beside the lines they belong to.
function M.notes_panel(analysis, page_win, width, height)
  local display, highlights = {}, {}
  for index = 1, height do
    display[index], highlights[index] = "", nil
  end

  local top = vim.fn.line("w0", page_win)
  local bottom = vim.fn.line("w$", page_win)

  for _, note in ipairs(analysis.notes) do
    if note.lnum >= top and note.lnum <= bottom then
      local anchor = screen_row(page_win, note.lnum, note.col)
      anchor = anchor and (anchor - row_offset(state.win))
      if anchor and anchor >= 1 then
        local wrapped = M.wrap(note.text, width - 2)
        -- Start beside the line, and slide down past anything already there.
        local at = anchor
        while at <= height and display[at] ~= "" do
          at = at + 1
        end
        for index, line in ipairs(wrapped) do
          local target = at + index - 1
          if target > height then
            break
          end
          display[target] = (index == 1 and "▏ " or "  ") .. line
          highlights[target] = "FountainInspectorNote"
        end
      end
    end
  end

  return display, highlights
end

--------------------------------------------------------------------- the window

--- Where you are in the script, by scene.
function M.header(analysis, mode, scene)
  if mode == "notes" then
    -- No winbar: in this mode the column lines up with the page row for row,
    -- and a winbar would push every note one row off its line.
    return ""
  end
  local where = scene and (scene.number .. "/" .. analysis.scene_count) or ""
  return "%#FountainInspectorHeader#SCENE%=" .. where .. " "
end

function M.refresh(opts)
  if not M.is_open() or not state.source or not vim.api.nvim_buf_is_valid(state.source) then
    return
  end
  local page_win = zen.win()
  if not page_win or not vim.api.nvim_win_is_valid(page_win) then
    return
  end

  local width = vim.api.nvim_win_get_width(state.win)
  local height = vim.api.nvim_win_get_height(state.win)
  local analysis = script.analyse(state.source, opts)
  local mode = M.mode()

  local lnum = vim.api.nvim_win_get_cursor(page_win)[1]

  -- The winbar is set first: the notes panel measures its rows against it.
  pcall(vim.api.nvim_set_option_value, "winbar", M.header(analysis, mode, script.scene_at(analysis, lnum)), {
    win = state.win,
    scope = "local",
  })

  local display, highlights
  if mode == "notes" then
    display, highlights = M.notes_panel(analysis, page_win, width, height)
  else
    display, highlights = M.scene_panel(analysis, lnum, width)
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, display)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, M.ns, 0, -1)
  for index, group in pairs(highlights) do
    if group and display[index] and display[index] ~= "" then
      pcall(vim.api.nvim_buf_set_extmark, state.buf, M.ns, index - 1, 0, {
        end_row = index - 1,
        end_col = #display[index],
        hl_group = group,
        priority = 200,
      })
    end
  end
end

local function ensure_buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].filetype = "fountain_inspector"
  vim.bo[state.buf].modifiable = false
  vim.keymap.set("n", "<Esc>", function()
    local page = zen.win()
    if page and vim.api.nvim_win_is_valid(page) then
      pcall(vim.api.nvim_set_current_win, page)
    end
  end, { buffer = state.buf, nowait = true, silent = true })
  return state.buf
end

local function setup_autocmds()
  state.augroup = vim.api.nvim_create_augroup("FountainStudioInspector", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = state.augroup,
    buffer = state.source,
    callback = function()
      M.refresh({ stale_ok = true })
    end,
  })
  vim.api.nvim_create_autocmd({ "WinScrolled", "VimResized" }, {
    group = state.augroup,
    callback = function()
      M.refresh({ stale_ok = true })
    end,
  })

  local remeasure = util.debouncer(config.get().refresh_delay, function()
    M.refresh()
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = state.augroup,
    buffer = state.source,
    callback = remeasure,
  })
end

function M.open(source, mode)
  if mode then
    state.mode = mode
  end
  if M.is_open() then
    M.refresh()
    return state.win
  end
  if not zen.is_open() then
    vim.notify("fountain: the inspector needs the page (:FountainZen)", vim.log.levels.WARN)
    return nil
  end
  local geometry = M.layout()
  if not geometry then
    return nil
  end

  state.source = source or vim.api.nvim_get_current_buf()
  state.win = vim.api.nvim_open_win(
    ensure_buffer(),
    false,
    vim.tbl_extend("force", geometry, { noautocmd = true })
  )

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
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  local win = state.win
  state.win, state.source = nil, nil
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

--- Switch mode, opening the inspector if it is not up.
function M.set_mode(mode)
  state.mode = mode
  if M.is_open() then
    M.refresh()
  else
    M.open(nil, mode)
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("FountainStudioInspectorLifecycle", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FountainStudioZenOpen",
    callback = function()
      if config.get().inspector.enabled then
        vim.schedule(function()
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
