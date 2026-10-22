local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local api = vim.api
local a = T.file("a.lua", { "one", "two", "three", "four" })
local b = T.file("b.lua", { "uno", "dos" })
local long = {}
for i = 1, 200 do
  long[i] = "line " .. i
end
local big = T.file("big.lua", long)

-- Headless nvim has no UI; pretend one is attached unless a test detaches it.
local attached = true
api.nvim_list_uis = function() return attached and { {} } or {} end

local DWELL = 1000

local function viewed_ids() return AgentNotes.viewed().viewed end

local function viewed(id)
  for _, n in ipairs(AgentNotes.list()) do
    if n.id == id then return n.viewed end
  end
end

-- The channel file's events, decoded.
local function events(channel) return vim.tbl_map(vim.json.decode, vim.fn.readfile(channel)) end

-- Puts the cursor on line in path's buffer in the first normal window, as the
-- user would, then fires event (headless nvim fires no cursor events by itself).
local function rest_on(path, line, event)
  vim.cmd "silent! only"
  vim.cmd.edit(path)
  api.nvim_win_set_cursor(0, { line, 0 })
  api.nvim_exec_autocmds(event or "CursorMoved", {})
end

T.test("nothing counts as viewed while no UI is attached", function()
  AgentNotes.setup()
  attached = false
  local channel = AgentNotes.channel "detached"
  local id = AgentNotes.add { file = a, line = 1, text = "first", channel = channel }
  AgentNotes.jump(1)
  attached = true
  T.eq(false, viewed(id), "viewed")
  T.eq({}, events(channel), "no view event")
end)

T.test("stepping marks the note shown, writes one view event, and summary and viewed() report it", function()
  AgentNotes.setup { display = "inline" }
  local channel = AgentNotes.channel "steps"
  local one = AgentNotes.add { file = a, line = 1, text = "one", channel = channel }
  local two = AgentNotes.add { file = a, line = 2, end_line = 3, text = "two", channel = channel }
  local three = AgentNotes.add { file = b, line = 1, text = "three", channel = channel }
  AgentNotes.next()
  AgentNotes.prev()
  T.eq({ viewed = { one, three }, unviewed = { two } }, AgentNotes.viewed())
  T.eq("viewed: #" .. one .. " #" .. three .. "\nunviewed: #" .. two, T.messages[#T.messages], "printed")
  T.ok(AgentNotes.summary():find("2. #" .. two .. " [info] [unviewed] " .. a .. ":2-3  two", 1, true), "summary")
  local first = AgentNotes.list()[1]
  T.ok(first.first_viewed and first.last_viewed, "view times")
  AgentNotes.jump(1)
  AgentNotes.jump(1)
  local got = events(channel)
  T.eq(2, #got, "first views only")
  T.eq(
    { "view", one, 1, a, 1, "one" },
    { got[1].type, got[1].note, got[1].order, got[1].file, got[1].line, got[1].excerpt }
  )
  T.eq(first.first_viewed, got[1].time, "event time")
  T.ok(not vim.fn.readfile(channel)[1]:find('"type":"reply"', 1, true), "a reply monitor ignores it")
end)

T.test("opening or entering the float marks the notes in it", function()
  AgentNotes.setup { display = "inline" }
  local shown = AgentNotes.add { file = a, line = 1, text = "shown" }
  local entered = AgentNotes.add { file = a, line = 3, text = "entered" }
  rest_on(a, 1)
  AgentNotes.show()
  T.eq({ shown }, viewed_ids(), "show")
  AgentNotes.show()
  rest_on(a, 3)
  AgentNotes.enter()
  T.eq({ shown, entered }, viewed_ids(), "enter")
end)

T.test("autofloat on a step marks the note", function()
  AgentNotes.setup { display = "float" }
  local id = AgentNotes.add { file = a, line = 2, text = "floated" }
  AgentNotes.jump(1)
  T.ok(AgentNotes._state.float, "float open")
  T.eq({ id }, viewed_ids())
end)

T.test("a float opened before the UI attached counts once the user rests there", function()
  AgentNotes.setup { display = "float" }
  attached = false
  local id = AgentNotes.add { file = a, line = 2, text = "waiting" }
  AgentNotes.jump(1)
  attached = true
  T.eq(false, viewed(id), "not before attaching")
  api.nvim_exec_autocmds("UIEnter", {})
  T.ok(vim.wait(DWELL * 2, function() return viewed(id) end), "viewed after attaching")
end)

T.test("opening the chat marks the note", function()
  AgentNotes.setup { display = "inline" }
  local channel = AgentNotes.channel "chat"
  local id = AgentNotes.add { file = a, line = 4, text = "reply to me", channel = channel }
  rest_on(a, 4)
  AgentNotes.reply()
  T.ok(AgentNotes._state.chat, "chat open")
  T.eq({ id }, viewed_ids())
  T.eq("view", events(channel)[1].type, "view event")
end)

T.test("selecting a note in the notes list marks it", function()
  AgentNotes.setup { display = "inline" }
  AgentNotes.add { file = a, line = 1, text = "first" }
  local second = AgentNotes.add { file = b, line = 2, text = "second" }
  AgentNotes.open()
  api.nvim_exec_autocmds("CursorMoved", {})
  T.eq({}, viewed_ids(), "opening the list views nothing")
  vim.cmd "cc 2"
  api.nvim_exec_autocmds("CursorMoved", {})
  T.eq({ second }, viewed_ids())
  vim.cmd "cclose"
end)

T.test("following a link marks the notes where it lands", function()
  AgentNotes.setup { display = "inline" }
  local target = AgentNotes.add { file = b, line = 2, text = "target" }
  AgentNotes.add { file = a, line = 1, text = "see [[" .. b .. ":2]]" }
  rest_on(a, 1)
  AgentNotes.follow()
  T.eq(b, api.nvim_buf_get_name(0), "landed")
  T.eq({ target }, viewed_ids())
end)

T.test("resting on a note's lines marks it, also when a UI attaches there", function()
  AgentNotes.setup { display = "inline" }
  local id = AgentNotes.add { file = a, line = 2, end_line = 3, text = "rest" }
  local other = AgentNotes.add { file = a, line = 1, text = "elsewhere" }
  rest_on(a, 3, "UIEnter")
  T.eq(false, viewed(id), "not before the dwell")
  T.ok(vim.wait(DWELL * 2, function() return viewed(id) end), "viewed after resting")
  T.eq(false, viewed(other), "other line")
end)

T.test("passing over a note, hidden inline text, or an off-screen first line does not count", function()
  AgentNotes.setup { display = "inline" }
  local passed = AgentNotes.add { file = a, line = 2, text = "passed" }
  rest_on(a, 2)
  vim.wait(DWELL / 4)
  rest_on(a, 4)
  local tall = AgentNotes.add { file = big, line = 1, end_line = 150, text = "tall" }
  AgentNotes.inline(false)
  rest_on(a, 2)
  vim.wait(DWELL + 300)
  T.eq({}, viewed_ids(), "passed over, or text hidden")
  AgentNotes.inline(true)
  rest_on(big, 150)
  vim.cmd "normal! zt"
  T.ok(vim.fn.line "w0" > 1, "first line off screen")
  vim.wait(DWELL + 300)
  T.eq(false, viewed(tall), "off screen")
  T.eq(false, viewed(passed), "passed")
end)

T.test("add with viewed = true carries the state forward without an event", function()
  AgentNotes.setup { display = "inline" }
  local channel = AgentNotes.channel "carry"
  local id = AgentNotes.add { file = a, line = 1, text = "seen before", channel = channel, viewed = true }
  T.eq(true, viewed(id), "viewed")
  AgentNotes.add { file = a, line = 2, text = "x" }
  local again = AgentNotes.add { file = a, line = 2, text = "x", viewed = true }
  T.eq(true, viewed(again), "an identical re-add marks the existing note")
  AgentNotes.jump(1)
  T.eq({}, events(channel), "no event for a carried-forward view")
  T.raises("viewed must be a boolean", function() AgentNotes.add { file = a, line = 1, text = "t", viewed = "yes" } end)
end)

T.test(":AgentNotes viewed prints the report", function()
  AgentNotes.add { file = a, line = 1, text = "one" }
  vim.cmd "AgentNotes viewed"
  T.eq("viewed: none\nunviewed: #" .. AgentNotes.list()[1].id, T.messages[#T.messages])
  AgentNotes.clear()
  T.eq({ viewed = {}, unviewed = {} }, AgentNotes.viewed())
  T.eq("No agent notes", T.messages[#T.messages])
end)

T.run()
