-- Registers :AgentNotes and a <Plug>(AgentNotes...) map per action, and loads the
-- module so agents can call the global AgentNotes table. Unless setup() has already
-- run, maps the default keys to the <Plug> maps now, as before setup() existed, so
-- the user's config can still override or delete them; setup() replaces them.
if vim.g.loaded_agent_notes then return end
vim.g.loaded_agent_notes = true

local api = vim.api
local config = require "agent-notes.config"

-- Re-requires every agent-notes module. Notes, channels, threads and options live in
-- the global AgentNotes table, which the new module picks up.
local function reload()
  for name in pairs(package.loaded) do
    if name == "agent-notes" or name:find("agent-notes.", 1, true) == 1 then package.loaded[name] = nil end
  end
  local notes = require "agent-notes"
  if notes._state.opts then notes.setup(notes._state.opts) end
end

-- Looked up on each call, so the functions stay current after :AgentNotes reload.
-- An action that takes a count gets it; the others get no argument.
local actions, counted = {}, {}
for _, a in ipairs(config.ACTIONS) do
  counted[a.name] = a.count
  actions[a.name] = function(count)
    if a.name == "reload" then return reload() end
    local notes = require "agent-notes"
    if a.replies and not notes._state.config.replies then
      return vim.notify("AgentNotes: replies are off (setup option replies = false)", vim.log.levels.WARN)
    end
    notes[a.fn or a.name](a.count and count or nil)
  end
  vim.keymap.set("n", config.plug(a.name), function() actions[a.name](vim.v.count1) end, { desc = a.desc })
end

-- Completes the action, the command's first argument only: nothing once a word
-- follows the command name. That is the first word that starts with "A" after the
-- last |, past any modifiers such as :silent.
local function complete(lead, line, pos)
  local cmd = line:sub(1, pos - #lead):match "[^|]*$"
  local args = cmd:match "%f[%w]A%w*!?%s+(.*)$"
  if args and args:find "%S" then return {} end
  local replies = require("agent-notes")._state.config.replies
  local out = {}
  for _, a in ipairs(config.ACTIONS) do
    if replies or not a.replies then out[#out + 1] = a.name end
  end
  return out
end

api.nvim_create_user_command("AgentNotes", function(o)
  local name, count = o.fargs[1] or "list", o.fargs[2]
  local action = actions[name]
  if not action then error("AgentNotes: unknown action " .. name, 0) end
  if o.fargs[3] or (count and not counted[name]) then
    error(("AgentNotes: too many arguments for %s"):format(name), 0)
  end
  if count and not count:find "^[1-9]%d*$" then
    error(("AgentNotes: count must be a whole number above 0, got %s"):format(count), 0)
  end
  action(tonumber(count))
end, { nargs = "*", bar = true, complete = complete, desc = "Agent notes" })

local notes = require "agent-notes"
if not notes._state.opts then config.apply_keymaps(notes._state.config, notes._state) end
