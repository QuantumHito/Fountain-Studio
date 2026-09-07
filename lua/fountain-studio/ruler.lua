-- The page ruler: a thin column beside the page marking where each printed
-- page begins.
--
-- Its contents are aligned to screen rows rather than to buffer lines, so a
-- mark sits exactly beside the line that opens the page, however the text above
-- it happens to wrap.
local config = require("fountain-studio.config")
local layout = require("fountain-studio.layout")
local parser = require("fountain-studio.parser")
local script = require("fountain-studio.script")
local util = require("fountain-studio.util")
local zen = require("fountain-studio.zen")

local M = {}

M.ns = vim.api.nvim_create_namespace("fountain-studio-ruler")

local state = { win = nil, buf = nil, source = nil, augroup = nil }

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.win()
  return M.is_open() and state.win or nil
end

function M.buf()
  return (state.buf and vim.api.nvim_buf_is_valid(state.buf)) and state.buf or nil
end

function M.layout()
  return layout.margins().ruler
end

--- The mark drawn where a page opens: a short rule and the page number.
function M.mark(page, width)
  local number = tostring(page)
  local rule = math.max(1, width - #number - 1)
  return string.rep("─", rule) .. " " .. number
end

--- Which screen row of the page window a buffer line is drawn on, counting
--- from 1, or nil when it is not on screen.
local function screen_row(page_win, lnum)
  local position = vim.fn.screenpos(page_win, lnum, 1)
  if position.row == 0 then
    return nil
  end
  local top = vim.api.nvim_win_get_position(page_win)[1]
  return position.row - top
end

--- A winbar takes the first row of a window, pushing its buffer down one, so a
--- column that lines up with the page must offset by it. The ruler carries no
--- winbar for exactly this reason; the offset is here so that setting one does
--- not silently misalign every mark.
local function row_offset(win)
  local winbar = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
  return (winbar ~= nil and winbar ~= "") and 1 or 0
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
  local rows = {}
  for index = 1, height do
    rows[index] = ""
  end

  local top = vim.fn.line("w0", page_win)
  local bottom = vim.fn.line("w$", page_win)
  local cursor_page = script.page_of(analysis, vim.api.nvim_win_get_cursor(page_win)[1])
  M.page = cursor_page -- the outline's header reports it
  local marks = {}

  for lnum = top, bottom do
    local page = script.page_of(analysis, lnum)
    local previous = lnum > 1 and script.page_of(analysis, lnum - 1) or 0
    if page ~= previous then
      local row = screen_row(page_win, lnum)
      row = row and (row - row_offset(state.win))
      if row and row >= 1 and row <= height then
        rows[row] = M.mark(page, width)
        marks[row] = page
      end
    end
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, rows)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, M.ns, 0, -1)
  for row, page in pairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, state.buf, M.ns, row - 1, 0, {
      end_row = row - 1,
      end_col = #rows[row],
      hl_group = page == cursor_page and "FountainRulerCurrent" or "FountainRuler",
      priority = 200,
    })
  end
end

local function ensure_buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].filetype = "fountain_ruler"
  vim.bo[state.buf].modifiable = false
  return state.buf
end

local function setup_autocmds()
  state.augroup = vim.api.nvim_create_augroup("FountainStudioRuler", { clear = true })

  -- Moving and scrolling are cheap against the analysis already in hand.
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

  -- Re-measuring the script waits for a pause in typing.
  local remeasure = util.debouncer(config.get().refresh_delay, function()
    M.refresh()
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = state.augroup,
    buffer = state.source,
    callback = remeasure,
  })
end

function M.open(source)
  if M.is_open() then
    return state.win
  end
  if not zen.is_open() then
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
    vim.tbl_extend("force", geometry, { noautocmd = true, focusable = false })
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

function M.setup()
  local group = vim.api.nvim_create_augroup("FountainStudioRulerLifecycle", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FountainStudioZenOpen",
    callback = function()
      if config.get().ruler.enabled then
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
