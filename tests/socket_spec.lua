local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local socket = require "agent-notes.socket"
local cache = vim.fn.stdpath "cache"
local default = cache .. "/default.sock"

local function listening(path) return vim.tbl_contains(vim.fn.serverlist(), path) end

local function stop(path)
  if listening(path) then vim.fn.serverstop(path) end
  os.remove(path)
end

T.test("path is default.sock outside herdr and per workspace inside it", function()
  T.eq(default, socket.path())
  vim.env.HERDR_WORKSPACE_ID = "w 1/x"
  T.eq(cache .. "/herdr-w_1_x.sock", socket.path())
  vim.env.HERDR_WORKSPACE_ID = nil
end)

T.test("no socket by default", function()
  AgentNotes.setup()
  T.ok(not listening(default), "not listening")
  T.eq(0, #vim.api.nvim_get_autocmds { group = "agent_notes_socket" })
end)

T.test("socket = true claims the socket now and on focus", function()
  AgentNotes.setup { socket = true }
  T.ok(listening(default), "listening")
  T.eq(1, #vim.api.nvim_get_autocmds { group = "agent_notes_socket", event = "FocusGained" })
  stop(default)
  vim.api.nvim_exec_autocmds("FocusGained", {})
  T.ok(listening(default), "re-claimed on focus")
  AgentNotes.setup { socket = false }
  T.eq(0, #vim.api.nvim_get_autocmds { group = "agent_notes_socket" })
  stop(default)
end)

T.test("a session nvim never claims the socket", function()
  vim.env.AGENT_NOTES_SESSION = "123"
  AgentNotes.setup { socket = true }
  vim.api.nvim_exec_autocmds("FocusGained", {})
  T.ok(not listening(default), "not listening")
  T.eq(0, #vim.api.nvim_get_autocmds { group = "agent_notes_socket" })
  vim.env.AGENT_NOTES_SESSION = nil
end)

T.test("a stale socket file is replaced", function()
  vim.fn.mkdir(cache, "p")
  vim.fn.writefile({}, default)
  socket.claim()
  T.ok(listening(default), "listening")
  stop(default)
end)

T.test("a socket owned by another live nvim is left alone", function()
  vim.fn.mkdir(cache, "p")
  local job = vim.fn.jobstart({ vim.v.progpath, "--clean", "--headless", "--listen", default })
  T.ok(vim.wait(5000, function() return vim.uv.fs_stat(default) ~= nil end), "other nvim listening")
  socket.claim()
  T.ok(not listening(default), "not claimed")
  vim.fn.jobstop(job)
  vim.fn.jobwait({ job }, 5000)
  T.ok(vim.wait(2000, function() return vim.uv.fs_stat(default) == nil end), "other nvim exited")
  socket.claim()
  T.ok(listening(default), "claimed after the owner exited")
  stop(default)
end)

T.test("setup rejects a non-boolean socket option", function()
  T.raises("socket must be a boolean, got string", function() AgentNotes.setup { socket = "yes" } end)
end)

T.run()
