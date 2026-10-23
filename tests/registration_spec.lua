local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local ACTIONS = {
  "autofloat", "clear", "enter", "follow", "inline", "lastreply", "list", "next", "prev",
  "reload", "replies", "reply", "show", "summary", "viewed",
}

T.test("the global API table exists at startup", function()
  T.ok(type(AgentNotes) == "table" and AgentNotes == require "agent-notes", "AgentNotes")
  for _, name in ipairs {
    "add", "open", "next", "prev", "jump", "show", "enter", "follow", "list", "summary", "viewed", "clear",
    "channel", "respond", "reply", "replies", "lastreply", "autofloat", "inline", "setup", "config",
  } do
    T.eq("function", type(AgentNotes[name]), name)
  end
end)

T.test(":AgentNotes completes every action and rejects unknown ones", function()
  local actions = vim.fn.getcompletion("AgentNotes ", "cmdline")
  table.sort(actions)
  T.eq(ACTIONS, actions)
  T.raises("AgentNotes: unknown action bogus", function() vim.cmd "AgentNotes bogus" end)
  vim.cmd "AgentNotes summary"
  T.eq("No agent notes", T.messages[#T.messages])
end)

T.test("every action has a <Plug> map that calls the current module after a reload", function()
  for _, name in ipairs(ACTIONS) do
    local plug = "<Plug>(AgentNotes" .. name:sub(1, 1):upper() .. name:sub(2) .. ")"
    T.ok(vim.fn.maparg(plug, "n", false, true).callback, plug)
  end
  vim.cmd "AgentNotes reload"
  local called = false
  local open = AgentNotes.open
  AgentNotes.open = function() called = true end
  vim.fn.maparg("<Plug>(AgentNotesList)", "n", false, true).callback()
  AgentNotes.open = open
  T.ok(called, "list calls open")
end)

T.run()
