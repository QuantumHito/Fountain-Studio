-- Highlight groups. Everything is defined with `default = true` so a colorscheme
-- or the user's own config wins.
local M = {}

M.groups = {
  FountainSceneHeading = { bold = true, link = nil },
  FountainCharacter = { bold = true },
  FountainParenthetical = { italic = true },
  FountainTransition = { italic = true },
  FountainCentered = {},
  FountainSection = { bold = true },
  FountainSynopsis = { italic = true },
  FountainLyrics = { italic = true },
  FountainTitlePage = {},
  FountainPageBreak = {},
  FountainNote = {},
  FountainBoneyard = {},
  FountainBold = { bold = true },
  FountainItalic = { italic = true },
  FountainBoldItalic = { bold = true, italic = true },
  FountainUnderline = { underline = true },
}

-- Colour comes from the colorscheme via these links; the attributes above are
-- merged on top.
M.links = {
  FountainSceneHeading = "Title",
  FountainCharacter = "Identifier",
  FountainParenthetical = "Comment",
  FountainTransition = "Statement",
  FountainCentered = "Special",
  FountainSection = "Title",
  FountainSynopsis = "Comment",
  FountainLyrics = "String",
  FountainTitlePage = "Special",
  FountainPageBreak = "NonText",
  FountainNote = "Comment",
  FountainBoneyard = "Comment",
}

function M.setup()
  for name, attrs in pairs(M.groups) do
    local link = M.links[name]
    if link then
      -- Link for colour, then re-apply the attributes we care about on top.
      local base = vim.api.nvim_get_hl(0, { name = link, link = false })
      local hl = vim.tbl_extend("force", base or {}, attrs)
      hl.default = true
      vim.api.nvim_set_hl(0, name, hl)
    else
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", attrs, { default = true }))
    end
  end

  -- The blanked-out margins behind the page.
  vim.api.nvim_set_hl(0, "FountainStudioBackdrop", { link = "Normal", default = true })
  -- The virtual indentation. Deliberately empty rather than linked to Normal:
  -- an attribute-less group inherits the background of whatever window it is
  -- drawn in, so the indent never shows as a block of a different colour when
  -- Normal and NormalFloat differ -- as they do in Catppuccin and most themes.
  vim.api.nvim_set_hl(0, "FountainStudioIndent", { default = true })
end

return M
