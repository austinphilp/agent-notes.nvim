local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local state = vim.fn.stdpath "state"
local new, legacy = state .. "/agent-notes/settings.json", state .. "/claude-notes/settings.json"

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ text }, path)
end

-- Loads the module as a new nvim session would, so it reads the settings again.
local function fresh()
  AgentNotes._state.autofloat = nil
  vim.cmd "AgentNotes reload"
  return AgentNotes._state.autofloat
end

local function reset()
  vim.fn.delete(state .. "/agent-notes", "rf")
  vim.fn.delete(state .. "/claude-notes", "rf")
end

T.test("on when no settings file exists", function()
  reset()
  T.eq(true, fresh())
end)

T.test("toggling saves the choice for the next session", function()
  reset()
  fresh()
  T.eq(false, AgentNotes.autofloat())
  T.eq({ autofloat = false }, vim.json.decode(vim.fn.readfile(new)[1]))
  T.eq(false, fresh())
  T.eq(true, AgentNotes.autofloat(true))
  T.eq(true, fresh())
end)

T.test("the legacy claude-notes file is read when the new one is missing", function()
  reset()
  write(legacy, '{"autofloat":false}')
  T.eq(false, fresh())
end)

T.test("the new file wins over the legacy one", function()
  reset()
  write(legacy, '{"autofloat":false}')
  write(new, '{"autofloat":true}')
  T.eq(true, fresh())
end)

T.test("a corrupt file means on", function()
  reset()
  write(new, "{not json")
  T.eq(true, fresh())
  write(new, '"autofloat"')
  T.eq(true, fresh())
end)

T.run()
