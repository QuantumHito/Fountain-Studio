-- Compiling the script to PDF with afterwriting.
--
-- afterwriting is a Node CLI (`npm install -g afterwriting`) that renders a
-- Fountain file to a properly formatted PDF. This shells out to it, which keeps
-- the pagination authoritative: afterwriting does the typesetting, not us.
--
-- One quirk shapes the whole module: afterwriting exits 0 even when it fails --
-- a missing source file prints "Cannot open script file" and still returns 0 --
-- so the exit status tells us nothing. Success is judged by its "Done!" line
-- and by a PDF actually being on disk.
local config = require("fountain-studio.config")

local M = {}

local uv = vim.uv or vim.loop

--- Where the PDF goes for `source`, unless the caller says otherwise.
function M.output_for(source, override)
  if override and override ~= "" then
    local path = vim.fn.fnamemodify(vim.fn.expand(override), ":p")
    if vim.fn.isdirectory(path) == 1 then
      return path:gsub("/*$", "") .. "/" .. vim.fn.fnamemodify(source, ":t:r") .. ".pdf"
    end
    return path
  end

  local directory = config.get().export.directory
  if directory and directory ~= "" then
    local base = vim.fn.fnamemodify(vim.fn.expand(directory), ":p"):gsub("/*$", "")
    return base .. "/" .. vim.fn.fnamemodify(source, ":t:r") .. ".pdf"
  end
  return (source:gsub("%.%w+$", "")) .. ".pdf"
end

--- The argv to run. Kept separate from running it so it can be tested without
--- afterwriting installed.
--- @return string[]
function M.command(source, output)
  local cfg = config.get().export
  local argv = { cfg.command }
  vim.list_extend(argv, cfg.args or {})
  vim.list_extend(argv, { "--source", source, "--pdf", output })

  if cfg.overwrite then
    table.insert(argv, "--overwrite")
  end
  if cfg.config_file and cfg.config_file ~= "" then
    vim.list_extend(argv, { "--config", vim.fn.expand(cfg.config_file) })
  end
  if cfg.fonts and cfg.fonts ~= "" then
    vim.list_extend(argv, { "--fonts", vim.fn.expand(cfg.fonts) })
  end
  for _, setting in ipairs(cfg.settings or {}) do
    vim.list_extend(argv, { "--setting", setting })
  end
  return argv
end

--- The one line worth showing from afterwriting's output: its last complaint,
--- with the banner it prints on every run dropped.
function M.reason(printed, wrote)
  local last
  for line in tostring(printed):gmatch("[^\r\n]+") do
    local text = vim.trim(line)
    local banner = text == ""
      or text:find("afterwriting", 1, true) ~= nil
      or text:find("www:", 1, true) ~= nil
      or text:find("^Loading script:") ~= nil
      or text:find("^Generating PDF") ~= nil
    if not banner then
      last = text
    end
  end
  if last then
    return last
  end
  return wrote and "afterwriting did not report finishing" or "no PDF was written"
end

function M.available()
  return vim.fn.executable(config.get().export.command) == 1
end

--- Hand the finished PDF to the system viewer.
function M.open(path)
  local opener = config.get().export.opener
  if not opener or opener == "" then
    if vim.fn.has("mac") == 1 then
      opener = "open"
    elseif vim.fn.has("win32") == 1 then
      opener = "explorer"
    else
      opener = "xdg-open"
    end
  end
  if vim.fn.executable(opener) ~= 1 then
    vim.notify("fountain: no PDF viewer (" .. opener .. ")", vim.log.levels.WARN)
    return
  end
  vim.system({ opener, path }, { detach = true })
end

--- Compile `bufnr` to PDF. Returns immediately; the result arrives as a
--- notification.
--- @param opts table|nil { bufnr, output, open }
function M.run(opts)
  opts = opts or {}
  local cfg = config.get().export
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local source = vim.api.nvim_buf_get_name(bufnr)

  if source == "" then
    vim.notify("fountain: save the script before exporting", vim.log.levels.ERROR)
    return
  end
  if not M.available() then
    vim.notify(
      ("fountain: %s not found -- npm install -g afterwriting"):format(cfg.command),
      vim.log.levels.ERROR
    )
    return
  end

  -- afterwriting reads the file, not the buffer, so unsaved work would be left
  -- out of the PDF without this.
  if cfg.write and vim.bo[bufnr].modified then
    local ok, err = pcall(function()
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent write")
      end)
    end)
    if not ok then
      vim.notify("fountain: could not save before export: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
  end

  local output = M.output_for(source, opts.output)
  local argv = M.command(source, output)
  local started = uv.hrtime()

  vim.system(argv, { text = true }, function(result)
    vim.schedule(function()
      local printed = (result.stdout or "") .. (result.stderr or "")
      local wrote = uv.fs_stat(output) ~= nil
      -- The exit code is not a signal here; "Done!" and a file on disk are.
      if wrote and printed:find("Done!", 1, true) then
        local ms = (uv.hrtime() - started) / 1e6
        vim.notify(
          ("fountain: %s (%.0f ms)"):format(vim.fn.fnamemodify(output, ":~:."), ms),
          vim.log.levels.INFO
        )
        if opts.open or cfg.open then
          M.open(output)
        end
      else
        vim.notify("fountain: export failed -- " .. M.reason(printed, wrote), vim.log.levels.ERROR)
      end
    end)
  end)
end

return M
