-- Fallback for setups that do not call setup() before the first Fountain
-- buffer. attach() is idempotent, so running here and from the plugin's own
-- FileType autocmd is harmless.
if vim.b.fountain_studio_attached then
  return
end

vim.bo.commentstring = "/* %s */"

local ok, fountain = pcall(require, "fountain-studio")
if ok then
  fountain.attach(0)
end
