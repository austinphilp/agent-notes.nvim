local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local KEYS = {
  n = "Next agent note",
  p = "Previous agent note",
  l = "Agent notes list",
  s = "Toggle agent note",
  e = "Enter agent note",
  g = "Follow agent note link",
  r = "Reply to agent note",
  f = "Toggle agent note float on step",
}

T.test("the global API table exists at startup", function()
  T.ok(type(AgentNotes) == "table" and AgentNotes == require "agent-notes", "AgentNotes")
  for _, name in ipairs {
    "add", "open", "next", "prev", "jump", "show", "enter", "follow", "list", "summary",
    "clear", "channel", "respond", "reply", "replies", "autofloat", "setup",
  } do
    T.eq("function", type(AgentNotes[name]), name)
  end
end)

T.test(":AgentNotes completes every action and rejects unknown ones", function()
  local actions = vim.fn.getcompletion("AgentNotes ", "cmdline")
  table.sort(actions)
  T.eq({
    "autofloat", "clear", "enter", "follow", "list", "next", "prev",
    "reload", "replies", "reply", "show", "summary",
  }, actions)
  T.raises("AgentNotes: unknown action bogus", function() vim.cmd "AgentNotes bogus" end)
  vim.cmd "AgentNotes summary"
  T.eq("No agent notes", T.messages[#T.messages])
end)

T.test("<Leader>a keymaps exist with their descriptions", function()
  for key, desc in pairs(KEYS) do
    T.eq(desc, vim.fn.maparg("<Leader>a" .. key, "n", false, true).desc, key)
  end
end)

T.test("keymaps call the current module after a reload", function()
  vim.cmd "AgentNotes reload"
  local called = false
  local next = AgentNotes.next
  AgentNotes.next = function() called = true end
  vim.fn.maparg("<Leader>an", "n", false, true).callback()
  AgentNotes.next = next
  T.ok(called, "next called")
end)

T.test("highlight groups link to diagnostic colours", function()
  for name, link in pairs {
    AgentNoteInfo = "DiagnosticInfo",
    AgentNoteWarn = "DiagnosticWarn",
    AgentNoteIssue = "DiagnosticError",
    AgentNoteYou = "DiagnosticOk",
    AgentNoteStep = "Comment",
  } do
    T.eq(link, vim.api.nvim_get_hl(0, { name = name }).link, name)
  end
end)

T.test("the which-key group is added after startup", function()
  local added
  package.loaded["which-key"] = { add = function(spec) added = spec end }
  vim.g.loaded_agent_notes = nil
  vim.cmd.runtime "plugin/agent-notes.lua"
  T.ok(vim.wait(1000, function() return added ~= nil end), "which-key add called")
  T.eq({ { "<Leader>a", group = "Agent notes" } }, added)
  package.loaded["which-key"] = nil
end)

T.run()
