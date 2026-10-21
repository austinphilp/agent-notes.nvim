local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local api = vim.api
local ns = api.nvim_create_namespace "agent_notes"
local file = T.file("step.lua", { "a", "b" })

local function mark()
  local marks = api.nvim_buf_get_extmarks(vim.fn.bufadd(file), ns, 0, -1, { details = true })
  T.eq(1, #marks, "one extmark")
  return marks[1][4]
end

local function float_open() return AgentNotes._state.float ~= nil and api.nvim_win_is_valid(AgentNotes._state.float.win) end

-- Adds a note, steps to it, and reports what showed.
local function step()
  AgentNotes.add { file = file, line = 2, text = "step" }
  AgentNotes.jump(1)
  T.eq(file, api.nvim_buf_get_name(0), "jumped to the file")
  T.eq(2, api.nvim_win_get_cursor(0)[1], "jumped to the line")
  local m = mark()
  T.eq("● ", m.sign_text, "sign")
  local shown = { inline = m.virt_lines ~= nil, float = float_open() }
  -- show() toggles the float in every mode.
  if float_open() then AgentNotes.show() end
  AgentNotes.show()
  T.ok(float_open(), "show opens the float")
  AgentNotes.show()
  T.ok(not float_open(), "show closes the float")
  return shown
end

for display, want in pairs {
  both = { inline = true, float = true },
  inline = { inline = true, float = false },
  float = { inline = false, float = true },
} do
  T.test(("display = %q"):format(display), function()
    AgentNotes.setup { display = display }
    T.eq(want, step())
  end)
end

T.test("the default display is both", function()
  AgentNotes.setup()
  T.eq({ inline = true, float = true }, step())
end)

T.test("the toggles change this session only and setup resets them", function()
  AgentNotes.setup { display = "inline" }
  T.eq(true, AgentNotes.autofloat())
  T.eq(false, AgentNotes.inline())
  T.eq({ inline = false, float = true }, step())
  T.eq(true, AgentNotes.inline(true))
  T.eq(false, AgentNotes.autofloat(false))
  T.eq({ inline = true, float = false }, step())
  vim.cmd "AgentNotes inline"
  T.eq(false, AgentNotes._state.inline, ":AgentNotes inline")
  vim.cmd "AgentNotes reload"
  T.eq({ inline = true, float = false }, step())
end)

T.test("inline toggles re-render notes already shown", function()
  AgentNotes.setup()
  AgentNotes.add { file = file, line = 1, text = "shown" }
  AgentNotes.inline(false)
  T.eq(nil, mark().virt_lines, "hidden")
  AgentNotes.inline(true)
  T.eq("shown", mark().virt_lines[1][3][1], "shown again")
end)

-- The old saved setting, plus a key the old code would drop when it saved again.
local SAVED = '{"autofloat":false,"kept":1}'

T.test("settings.json is neither read nor written", function()
  local state = vim.fn.stdpath "state"
  for _, dir in ipairs { "agent-notes", "claude-notes" } do
    vim.fn.mkdir(state .. "/" .. dir, "p")
    vim.fn.writefile({ SAVED }, state .. "/" .. dir .. "/settings.json")
  end
  -- Loads as a new nvim session would, before any setup().
  AgentNotes._state.config, AgentNotes._state.opts = nil, nil
  vim.cmd "AgentNotes reload"
  T.eq(true, AgentNotes._state.autofloat, "file ignored")
  AgentNotes.autofloat()
  for _, dir in ipairs { "agent-notes", "claude-notes" } do
    T.eq({ SAVED }, vim.fn.readfile(state .. "/" .. dir .. "/settings.json"), dir .. " untouched")
  end
end)

T.run()
