-- Sourced by bin/nvim-session into each session nvim. Quits the session once the
-- Claude Code process that owns it (AGENT_NOTES_SESSION, a pid) has exited and no UI
-- has been attached for NVIM_SESSION_IDLE seconds, so a session nobody stopped does
-- not run forever. Unsaved changes keep it running, since the user may come back.
local owner = tonumber(vim.env.AGENT_NOTES_SESSION)
local idle_ms = (tonumber(vim.env.NVIM_SESSION_IDLE) or 1800) * 1000
if not owner then return end

local function orphaned() return vim.uv.kill(owner, 0) ~= 0 and #vim.api.nvim_list_uis() == 0 end

local since -- when the session was first seen orphaned
local interval = math.min(idle_ms, 60000)
vim.uv.new_timer():start(
  interval,
  interval,
  vim.schedule_wrap(function()
    if not orphaned() then
      since = nil
      return
    end
    since = since or vim.uv.now()
    if vim.uv.now() - since >= idle_ms then pcall(vim.cmd.qall) end
  end)
)
