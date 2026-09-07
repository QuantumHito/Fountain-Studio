-- Where each panel goes.
--
-- The page is placed first and never gives up room; the margins are whatever is
-- left over. Each panel is dropped rather than squeezed when its share of the
-- margin falls below its minimum, so a narrow terminal loses panels one at a
-- time instead of showing a row of slivers.
local config = require("fountain-studio.config")
local zen = require("fountain-studio.zen")

local M = {}

--- Geometry for every panel: `page`, and any of `ruler`, `outline`,
--- `inspector` that fit. Absent panels are nil.
function M.margins()
  local cfg = config.get()
  local page = zen.layout().page
  local result = { page = page }

  local function panel(width, col)
    return {
      relative = "editor",
      width = width,
      height = page.height,
      row = page.row,
      col = col,
      style = "minimal",
      border = "none",
      focusable = true,
      zindex = 45, -- above the backdrop, below the page
    }
  end

  -- Left margin, page outwards: the ruler hugs the page, the outline sits
  -- beyond it. The ruler only takes its columns if the outline still fits
  -- afterwards -- the list is worth more than the tick marks.
  local left_edge = page.col
  local outline_needs = cfg.outline.enabled and (cfg.outline.min_width + cfg.outline.gap) or 0

  if cfg.ruler.enabled and left_edge >= cfg.ruler.width + cfg.ruler.gap + outline_needs then
    local col = left_edge - cfg.ruler.gap - cfg.ruler.width
    result.ruler = panel(cfg.ruler.width, col)
    left_edge = col
  end

  if cfg.outline.enabled then
    local available = left_edge - cfg.outline.gap
    if available >= cfg.outline.min_width then
      local width = math.min(cfg.outline.width, available)
      result.outline = panel(width, left_edge - cfg.outline.gap - width)
    end
  end

  -- Right margin.
  if cfg.inspector.enabled then
    local available = vim.o.columns - (page.col + page.width) - cfg.inspector.gap
    if available >= cfg.inspector.min_width then
      local width = math.min(cfg.inspector.width, available)
      result.inspector = panel(width, page.col + page.width + cfg.inspector.gap)
    end
  end

  return result
end

return M
