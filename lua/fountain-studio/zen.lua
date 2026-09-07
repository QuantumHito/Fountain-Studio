-- Centered page layout.
--
-- The script is moved into a floating window exactly one page-measure wide,
-- centered on the editor, with a full-screen blank float behind it hiding
-- everything else. The margins either side are real, empty screen space --
-- which is where the scene outline will live later.
local config = require("fountain-studio.config")

local M = {}

local state = {
  win = nil,
  buf = nil,
  origin = nil,
  view = nil,
  backdrop_win = nil,
  backdrop_buf = nil,
  opening = false,
  closing = false,
  quitting = false,
  forced = false,
  augroup = nil,
}

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.win()
  return M.is_open() and state.win or nil
end

function M.opening()
  return state.opening
end

local function tabline_rows()
  local show = vim.o.showtabline
  if show == 2 or (show == 1 and #vim.api.nvim_list_tabpages() > 1) then
    return 1
  end
  return 0
end

local function status_rows()
  return vim.o.laststatus > 0 and 1 or 0
end

--- Geometry for the page float and the backdrop behind it.
function M.layout()
  local cfg = config.get()
  local columns = vim.o.columns
  local top = tabline_rows()
  local usable_rows = math.max(1, vim.o.lines - vim.o.cmdheight - status_rows() - top)

  local width = math.min(cfg.width, math.max(1, columns - 2 * cfg.min_margin))
  if width < cfg.min_width then
    width = math.max(1, math.min(cfg.width, columns))
  end

  local col = math.floor((columns - width) / 2) + cfg.zen.offset
  col = math.max(0, math.min(col, math.max(0, columns - width)))

  local row = top + math.min(cfg.zen.pad_top, math.max(0, usable_rows - 1))
  local height = math.max(1, usable_rows - (row - top))

  return {
    page = {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      border = "none",
      focusable = true,
      zindex = 50,
    },
    backdrop = {
      relative = "editor",
      width = columns,
      height = usable_rows,
      row = top,
      col = 0,
      border = "none",
      focusable = false,
      zindex = 40,
      style = "minimal",
    },
    degraded = width < cfg.width,
  }
end

local function apply_winopts(win)
  local cfg = config.get()
  for name, value in pairs(cfg.winopts) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = "local" })
  end
  pcall(vim.api.nvim_set_option_value, "fillchars", "eob: ", { win = win, scope = "local" })
  if cfg.zen.winhighlight then
    pcall(vim.api.nvim_set_option_value, "winhighlight", cfg.zen.winhighlight, { win = win, scope = "local" })
  end
end

local function open_backdrop(geometry)
  local cfg = config.get()
  if not cfg.zen.backdrop then
    return
  end
  state.backdrop_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.backdrop_buf].bufhidden = "wipe"
  vim.bo[state.backdrop_buf].filetype = "fountain_backdrop"
  state.backdrop_win = vim.api.nvim_open_win(
    state.backdrop_buf,
    false,
    vim.tbl_extend("force", geometry, { noautocmd = true })
  )
  vim.api.nvim_set_option_value(
    "winhighlight",
    "Normal:FountainStudioBackdrop,NormalFloat:FountainStudioBackdrop,EndOfBuffer:FountainStudioBackdrop",
    { win = state.backdrop_win, scope = "local" }
  )
  vim.api.nvim_set_option_value("fillchars", "eob: ", { win = state.backdrop_win, scope = "local" })
end

local function close_backdrop()
  if state.backdrop_win and vim.api.nvim_win_is_valid(state.backdrop_win) then
    pcall(vim.api.nvim_win_close, state.backdrop_win, true)
  end
  state.backdrop_win, state.backdrop_buf = nil, nil
end

local function setup_autocmds()
  state.augroup = vim.api.nvim_create_augroup("FountainStudioZen", { clear = true })

  vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
    group = state.augroup,
    callback = function()
      M.resize()
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(args)
      if state.win and tonumber(args.match) == state.win then
        M.close({ from_winclosed = true, defer = true })
      end
    end,
  })

  -- `:q` in the page should quit the file, not just leave the layout. Closing a
  -- floating window never raises E37, so the quit is re-issued on the window the
  -- page came from, where the usual unsaved-changes rules apply again. The flag
  -- clears itself on the next tick so it cannot leak into a later close.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = state.augroup,
    callback = function()
      if M.is_open() and vim.api.nvim_get_current_win() == state.win then
        state.quitting = true
        -- Best effort at recovering the `!`: a forced quit must not be turned
        -- back into a refusal. Getting this wrong is safe -- the page comes back
        -- with the buffer untouched.
        local last = vim.fn.histget(":", -1) or ""
        state.forced = last:match("^%s*%a*[qx]%a*!") ~= nil
        vim.schedule(function()
          state.quitting, state.forced = false, false
        end)
      end
    end,
  })

  -- Opening something that is not a script inside the page ends the layout and
  -- hands that buffer back to the window the page came from.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
    group = state.augroup,
    callback = function(args)
      if not M.is_open() or state.opening then
        return
      end
      if vim.api.nvim_get_current_win() ~= state.win or args.buf == state.buf then
        return
      end
      local filetypes = config.get().filetypes or { "fountain" }
      if vim.tbl_contains(filetypes, vim.bo[args.buf].filetype) then
        state.buf = args.buf
        return
      end
      M.close({ defer = true })
    end,
  })

  -- Leaving the page for an ordinary window means zen is over; floating windows
  -- (pickers, completion, notifications) are left alone.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = state.augroup,
    callback = function()
      if not M.is_open() or state.opening then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win == state.win then
        return
      end
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        return
      end
      M.close({ defer = true })
    end,
  })
end

--- Move `bufnr` into a centered page float.
function M.open(bufnr, origin)
  local cfg = config.get()
  if not cfg.zen.enabled or M.is_open() then
    return M.win()
  end
  if state.closing then
    vim.schedule(function()
      M.open(bufnr, origin)
    end)
    return
  end

  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  origin = origin or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(origin) or vim.api.nvim_win_get_config(origin).relative ~= "" then
    origin = nil
  end

  local geometry = M.layout()
  state.opening = true
  local ok, err = pcall(function()
    state.buf = bufnr
    state.origin = origin
    state.view = origin and vim.api.nvim_win_call(origin, vim.fn.winsaveview) or nil

    open_backdrop(geometry.backdrop)
    state.win = vim.api.nvim_open_win(bufnr, true, geometry.page)
    apply_winopts(state.win)
    if state.view then
      vim.api.nvim_win_call(state.win, function()
        vim.fn.winrestview(state.view)
      end)
    end
    setup_autocmds()
  end)
  state.opening = false

  if not ok then
    close_backdrop()
    state.win = nil
    error(err)
  end

  vim.api.nvim_exec_autocmds("User", { pattern = "FountainStudioZenOpen", modeline = false })
  return state.win
end

function M.resize()
  if not M.is_open() then
    return
  end
  local geometry = M.layout()
  pcall(vim.api.nvim_win_set_config, state.win, geometry.page)
  if state.backdrop_win and vim.api.nvim_win_is_valid(state.backdrop_win) then
    pcall(vim.api.nvim_win_set_config, state.backdrop_win, geometry.backdrop)
  end
end

--- Read everything the rest of the close needs while the page window is still
--- there, and drop the state so nothing else tries to close it in the meantime.
local function capture()
  local snapshot = {
    win = state.win,
    origin = state.origin,
    quitting = state.quitting,
    forced = state.forced,
  }
  state.win, state.quitting, state.forced = nil, false, false

  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end

  if snapshot.win and vim.api.nvim_win_is_valid(snapshot.win) then
    snapshot.shown = vim.api.nvim_win_get_buf(snapshot.win)
    snapshot.view = vim.api.nvim_win_call(snapshot.win, vim.fn.winsaveview)
  end

  state.buf, state.origin, state.view = nil, nil, nil
  return snapshot
end

local function finish_close(snapshot, opts)
  if snapshot.win and vim.api.nvim_win_is_valid(snapshot.win) and not opts.from_winclosed then
    pcall(vim.api.nvim_win_close, snapshot.win, false)
  end

  close_backdrop()

  local origin = snapshot.origin
  if origin and vim.api.nvim_win_is_valid(origin) then
    -- If the user opened something else while in the page, keep it on screen.
    local shown = snapshot.shown
    if shown and vim.api.nvim_buf_is_valid(shown) and vim.api.nvim_win_get_buf(origin) ~= shown then
      pcall(vim.api.nvim_win_set_buf, origin, shown)
    end
    pcall(vim.api.nvim_set_current_win, origin)
    if snapshot.view then
      vim.api.nvim_win_call(origin, function()
        vim.fn.winrestview(snapshot.view)
      end)
    end
  end

  vim.api.nvim_exec_autocmds("User", { pattern = "FountainStudioZenClose", modeline = false })

  if snapshot.quitting then
    local forced, buffer = snapshot.forced, snapshot.shown
    vim.schedule(function()
      local quit_ok, err = pcall(vim.cmd, forced and "quit!" or "quit")
      if not quit_ok then
        -- Unsaved changes, most likely. Put the page back and report it, the
        -- way :q would have if the page had been an ordinary window.
        if buffer and vim.api.nvim_buf_is_valid(buffer) then
          pcall(M.open, buffer)
        end
        local message = tostring(err):match("E%d+:[^\n]*") or tostring(err)
        vim.notify(message, vim.log.levels.ERROR)
      end
    end)
  end
end

--- Leave the page layout.
---
--- `opts.defer` runs the window work on the next tick, which is what the
--- autocmds use: WinClosed fires "just before [the window] is removed from the
--- window layout", so closing the backdrop from inside it changes the layout
--- underneath Neovim while it is already changing it. Commands and mappings
--- close synchronously -- there is no layout change in progress to trip over.
function M.close(opts)
  opts = opts or {}
  if state.closing then
    return
  end

  local snapshot = capture()
  if not snapshot.win and not state.backdrop_win then
    return
  end

  if opts.defer then
    state.closing = true
    vim.schedule(function()
      state.closing = false
      finish_close(snapshot, opts)
    end)
  else
    finish_close(snapshot, opts)
  end
end

function M.toggle(bufnr)
  if M.is_open() then
    M.close()
  else
    M.open(bufnr)
  end
end

return M
