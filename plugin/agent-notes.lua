-- Registers :AgentNotes, the <Leader>a keymaps and the highlight groups, and loads
-- the module so agents can call the global AgentNotes table.
if vim.g.loaded_agent_notes then return end
vim.g.loaded_agent_notes = true

local api = vim.api

-- Kind is shown by colour only; colourschemes can override these links.
for name, link in pairs {
  AgentNoteInfo = "DiagnosticInfo",
  AgentNoteWarn = "DiagnosticWarn",
  AgentNoteIssue = "DiagnosticError",
  AgentNoteYou = "DiagnosticOk",
  AgentNoteStep = "Comment",
} do
  api.nvim_set_hl(0, name, { link = link, default = true })
end

-- Looked up on each call, so the functions stay current after :AgentNotes reload.
local function call(name)
  return function() require("agent-notes")[name]() end
end

-- Re-requires every agent-notes module. Notes, channels, threads and options live in
-- the global AgentNotes table, which the new module picks up.
local function reload()
  for name in pairs(package.loaded) do
    if name == "agent-notes" or name:find("agent-notes.", 1, true) == 1 then package.loaded[name] = nil end
  end
  local notes = require "agent-notes"
  if notes._state.opts then notes.setup(notes._state.opts) end
end

local actions = {
  next = call "next",
  prev = call "prev",
  list = call "open",
  show = call "show",
  enter = call "enter",
  follow = call "follow",
  reply = call "reply",
  replies = call "replies",
  autofloat = call "autofloat",
  summary = call "summary",
  clear = call "clear",
  reload = reload,
}
api.nvim_create_user_command("AgentNotes", function(o)
  local action = actions[o.args ~= "" and o.args or "list"]
  if not action then error("AgentNotes: unknown action " .. o.args, 0) end
  action()
end, { nargs = "?", bar = true, complete = function() return vim.tbl_keys(actions) end, desc = "Agent notes" })

-- <Leader>a mirrors the quickfix <Leader>xn / <Leader>xp pair.
for key, map in pairs {
  n = { "next", "Next agent note" },
  p = { "prev", "Previous agent note" },
  l = { "open", "Agent notes list" },
  s = { "show", "Toggle agent note" },
  e = { "enter", "Enter agent note" },
  g = { "follow", "Follow agent note link" },
  r = { "reply", "Reply to agent note" },
  f = { "autofloat", "Toggle agent note float on step" },
} do
  vim.keymap.set("n", "<Leader>a" .. key, call(map[1]), { desc = map[2] })
end
-- After startup, so a lazy-loaded which-key is set up by then.
vim.schedule(function()
  pcall(function() require("which-key").add { { "<Leader>a", group = "Agent notes" } } end)
end)

require "agent-notes"
