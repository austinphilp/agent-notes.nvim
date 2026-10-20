local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local a = T.file("a.lua", { "one", "two" })

T.test(":AgentNotes reload re-requires the modules and keeps notes and threads", function()
  local channel = AgentNotes.channel "reload"
  local id = AgentNotes.add { file = a, line = 2, kind = "warn", text = "kept", channel = channel }
  AgentNotes.respond(id, "answer")
  local before, api, text = AgentNotes.summary(), AgentNotes, require "agent-notes.text"
  vim.cmd "AgentNotes reload"
  T.ok(require "agent-notes.text" ~= text, "helper module re-required")
  T.ok(require "agent-notes" == api and AgentNotes == api, "same global table")
  T.eq(before, AgentNotes.summary(), "summary")
  T.eq("answer", AgentNotes.list()[1].thread[1].text, "thread")
  -- Rendering still works through the new modules.
  T.eq(id + 1, AgentNotes.add { file = a, line = 1, text = "after reload" }, "next id")
end)

T.test("reload re-applies setup options", function()
  AgentNotes.setup { socket = true }
  vim.cmd "AgentNotes reload"
  T.eq({ socket = true }, AgentNotes._state.opts)
  T.eq(1, #vim.api.nvim_get_autocmds { group = "agent_notes_socket", event = "FocusGained" })
end)

T.run()
