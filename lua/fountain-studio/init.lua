-- fountain-studio.nvim -- screenplay formatting for .fountain files.
local config = require("fountain-studio.config")
local highlight = require("fountain-studio.highlight")
local parser = require("fountain-studio.parser")
local render = require("fountain-studio.render")
local zen = require("fountain-studio.zen")

local M = {}

M.config = config
M.render = render
M.zen = zen
M.parser = parser

local did_setup = false
local warned_narrow = false

--- Teach Neovim about .fountain files. Safe to call before setup().
function M.register_filetype()
  vim.filetype.add({
    extension = {
      fountain = "fountain",
      spmd = "fountain",
    },
  })
end

-- Kept short on purpose: a message wider than the terminal triggers Neovim's
-- hit-enter prompt, and this only fires on terminals that are already narrow.
local function warn_if_narrow(win)
  if warned_narrow or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local width, degraded = render.measure(win)
  if degraded then
    warned_narrow = true
    vim.notify(("fountain: page narrowed to %d cols"):format(width), vim.log.levels.WARN)
  end
end

--- Set a Fountain buffer up: options, redraw triggers, and the page layout.
function M.attach(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].fountain_studio_attached then
    return
  end
  if not did_setup then
    M.setup({})
  end

  local cfg = config.get()
  vim.b[bufnr].fountain_studio_attached = true

  for name, value in pairs(cfg.bufopts) do
    pcall(vim.api.nvim_set_option_value, name, value, { buf = bufnr })
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      for name, value in pairs(cfg.winopts) do
        pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = "local" })
      end
    end
  end

  local group = vim.api.nvim_create_augroup("FountainStudioBuffer" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({
    "TextChanged",
    "TextChangedI",
    "TextChangedP",
    "InsertLeave",
    "BufWinEnter",
    "WinScrolled",
    "WinResized",
  }, {
    group = group,
    buffer = bufnr,
    callback = function()
      render.render_buffer(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })

  if cfg.zen.enabled and cfg.zen.auto and not zen.is_open() and not zen.opening() then
    vim.schedule(function()
      if vim.api.nvim_get_current_buf() == bufnr and not zen.is_open() then
        pcall(zen.open, bufnr)
      end
      render.render_buffer(bufnr)
      warn_if_narrow(vim.api.nvim_get_current_win())
    end)
  else
    vim.schedule(function()
      render.render_buffer(bufnr)
    end)
  end
end

local function create_commands()
  vim.api.nvim_create_user_command("FountainZen", function()
    zen.toggle()
  end, { desc = "Toggle the centered screenplay page" })

  vim.api.nvim_create_user_command("FountainFormat", function()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.b[bufnr].fountain_studio_format = not render.enabled(bufnr)
    render.render_buffer(bufnr)
    vim.notify(
      "fountain-studio: formatting " .. (render.enabled(bufnr) and "on" or "off"),
      vim.log.levels.INFO
    )
  end, { desc = "Toggle Fountain visual formatting in this buffer" })

  vim.api.nvim_create_user_command("FountainInspect", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local kind = parser.classify_line(bufnr, lnum, config.get()) or "?"
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    local width, degraded = render.measure(win)
    vim.notify(
      ("fountain-studio: line %d is %s, indent %d, measure %d%s")
        :format(lnum, kind, render.indent_for(kind, line, width), width, degraded and " (narrowed)" or ""),
      vim.log.levels.INFO
    )
  end, { desc = "Report how the current line is being formatted" })
end

function M.setup(opts)
  if did_setup then
    if opts and not vim.tbl_isempty(opts) then
      config.setup(opts)
    end
    return
  end
  did_setup = true

  config.setup(opts)
  M.register_filetype()
  highlight.setup()

  local group = vim.api.nvim_create_augroup("FountainStudio", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = highlight.setup,
  })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = config.get().filetypes or "fountain",
    callback = function(args)
      M.attach(args.buf)
    end,
  })

  create_commands()
end

return M
