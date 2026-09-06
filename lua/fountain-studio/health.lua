-- :checkhealth fountain-studio
local config = require("fountain-studio.config")

local M = {}

function M.check()
  local health = vim.health
  health.start("fountain-studio")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ is required for inline virtual text (indentation is drawn with it)")
  end

  local cfg = config.get()
  local columns = vim.o.columns
  local needed = cfg.width + 2 * cfg.min_margin
  if columns >= needed then
    health.ok(("terminal is %d columns; a %d-column page fits with room to spare"):format(columns, cfg.width))
  elseif columns >= cfg.min_width then
    health.warn(
      ("terminal is %d columns; %d are needed for a full page, so it will be scaled down")
        :format(columns, needed),
      { "Widen the terminal, or lower `width` if you write to a narrower measure." }
    )
  else
    health.error(("terminal is only %d columns wide"):format(columns))
  end

  if vim.fn.exists("+conceallevel") == 1 then
    health.ok("conceal is available (emphasis markers and forced-element markers can be hidden)")
  end

  local detected = vim.filetype.match({ filename = "script.fountain" })
  if detected == "fountain" then
    health.ok("*.fountain files are detected as `fountain`")
  else
    health.warn("*.fountain is not registered", {
      "Call require('fountain-studio').register_filetype() from your plugin spec's init().",
    })
  end
end

return M
