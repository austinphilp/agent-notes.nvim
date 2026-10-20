-- Listens on a well-known socket so agents can drive this nvim (bin/nvim-mcp derives
-- the same paths): one per herdr workspace inside herdr, and default.sock outside it.
-- The first nvim on a path owns the socket; later ones keep only their default
-- server address and claim it on focus once the owner has exited.
local M = {}

--- The socket path for this nvim: herdr-<workspace>.sock inside herdr, else default.sock.
function M.path()
  local dir = vim.fn.stdpath "cache"
  local workspace = vim.env.HERDR_WORKSPACE_ID
  return workspace and workspace ~= "" and ("%s/herdr-%s.sock"):format(dir, (workspace:gsub("[^%w_-]", "_")))
    or dir .. "/default.sock"
end

--- Starts listening on path() unless this nvim already does or another live nvim owns it.
function M.claim()
  local path = M.path()
  if vim.tbl_contains(vim.fn.serverlist(), path) then return end

  if vim.uv.fs_stat(path) then
    local ok, chan = pcall(vim.fn.sockconnect, "pipe", path, { rpc = true })
    if ok and chan > 0 then
      vim.fn.chanclose(chan)
      return -- another live nvim owns the socket
    end
    os.remove(path) -- stale socket left by an nvim that did not exit cleanly
  end

  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, err = pcall(vim.fn.serverstart, path)
  if not ok then vim.notify(("agent socket %s unavailable: %s"):format(path, err), vim.log.levels.WARN) end
end

--- Claims the socket now and on every FocusGained. With on = false it stops claiming;
--- a socket already claimed stays until nvim exits, since it may also be one the user
--- started with --listen.
function M.enable(on)
  local group = vim.api.nvim_create_augroup("agent_notes_socket", { clear = true })
  if not on then return end
  M.claim()
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = M.claim })
end

return M
