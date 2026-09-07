local M = {}

local uv = vim.uv or vim.loop

--- Wrap `fn` so it runs once things have been quiet for `ms` milliseconds.
function M.debouncer(ms, fn)
  local timer
  return function(...)
    local args = { ... }
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    timer = uv.new_timer()
    timer:start(
      ms,
      0,
      vim.schedule_wrap(function()
        if timer then
          timer:stop()
          timer:close()
          timer = nil
        end
        fn(unpack(args))
      end)
    )
  end
end

return M
