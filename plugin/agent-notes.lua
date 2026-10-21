-- Registers :AgentNotes and a <Plug>(AgentNotes...) map per action, and loads the
-- module so agents can call the global AgentNotes table. setup() maps the keys to
-- the <Plug> maps; without a setup() call, the default keys are mapped at VimEnter.
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
local actions = {}
for _, a in ipairs(config.ACTIONS) do
  actions[a.name] = function()
    if a.name == "reload" then return reload() end
    local notes = require "agent-notes"
    if a.replies and not notes._state.config.replies then
      return vim.notify("AgentNotes: replies are off (setup option replies = false)", vim.log.levels.WARN)
    end
    notes[a.fn or a.name]()
  end
  vim.keymap.set("n", config.plug(a.name), actions[a.name], { desc = a.desc })
end

local function complete()
  local replies = require("agent-notes")._state.config.replies
  local out = {}
  for _, a in ipairs(config.ACTIONS) do
    if replies or not a.replies then out[#out + 1] = a.name end
  end
  return out
end

api.nvim_create_user_command("AgentNotes", function(o)
  local action = actions[o.args ~= "" and o.args or "list"]
  if not action then error("AgentNotes: unknown action " .. o.args, 0) end
  action()
end, { nargs = "?", bar = true, complete = complete, desc = "Agent notes" })

local notes = require "agent-notes"

-- A config's own setup() call, or lazy.nvim's, comes before VimEnter. When this file
-- loads after startup, setup() may follow right after it, so wait a tick.
local function defaults()
  if not notes._state.opts then notes.setup() end
end
if vim.v.vim_did_enter == 1 then
  vim.schedule(defaults)
else
  api.nvim_create_autocmd("VimEnter", { once = true, callback = defaults })
end
