local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local api = vim.api
local a = T.file("a.lua", { "one", "two", "three" })

-- Headless nvim has no UI; pretend one is attached so reads count.
api.nvim_list_uis = function() return { {} } end
vim.o.columns = 300

-- The notes list's lines after each location, opening the list first.
local function entries()
  AgentNotes.open()
  local out = {}
  for _, l in ipairs(api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false)) do
    out[#out + 1] = l:match "^[^|]*|[^|]*| (.*)$"
  end
  return out
end

-- The foreground drawn at the first cell of needle in the notes list. The selected
-- entry is drawn with QuickFixLine, so tests check other entries.
local function fg_of(needle)
  AgentNotes.open()
  local win = api.nvim_get_current_win()
  vim.cmd "redraw!"
  for row, l in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
    local col = l:find(needle, 1, true)
    if col then
      local pos = vim.fn.screenpos(win, row, col)
      return api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)[2].foreground
    end
  end
  error("not in the list: " .. needle)
end

local function fg(group) return api.nvim_get_hl(0, { name = group, link = false }).fg end

local function chan() return AgentNotes.channel(("c%d"):format(vim.uv.hrtime())) end

local function float_lines()
  local f = AgentNotes._state.float
  return f and api.nvim_buf_get_lines(api.nvim_win_get_buf(f.win), 0, -1, false)
end

local function toast_text()
  local t = AgentNotes._state.toast
  return t and api.nvim_win_is_valid(t.win) and api.nvim_buf_get_lines(api.nvim_win_get_buf(t.win), 0, -1, false)[1]
end

local function cleanup()
  vim.cmd "cclose"
  vim.cmd "silent! only"
  AgentNotes.setup()
end

T.test("the list shows the summary or the first line, without the kind word", function()
  AgentNotes.setup()
  AgentNotes.add { file = a, line = 1, kind = "warn", text = "First **line**\nmore", summary = "Short summary" }
  AgentNotes.add { file = a, line = 2, text = "Second" }
  T.eq({ "1. ▲ Short summary", "2. ● Second" }, entries())
  AgentNotes.setup { list_text = "text" }
  T.eq({ "1. ▲ First **line**", "2. ● Second" }, entries(), "list_text = text")
  cleanup()
end)

T.test("summary is one line, kept through re-adds, and reported", function()
  AgentNotes.setup()
  for _, bad in ipairs { "a\nb", 5, "  " } do
    T.raises("AgentNotes.add: summary must be a non-empty one-line string", function()
      AgentNotes.add { file = a, line = 1, text = "x", summary = bad }
    end)
  end
  local id = AgentNotes.add { file = a, line = 1, text = "Body", summary = "Gist" }
  T.eq(id, AgentNotes.add { file = a, line = 1, text = "Body" })
  T.eq("Gist", AgentNotes.list()[1].summary, "kept by a re-add without one")
  AgentNotes.add { file = a, line = 1, text = "Body", summary = "New gist" }
  T.eq("New gist", AgentNotes.list()[1].summary, "replaced by a re-add with one")
  T.ok(AgentNotes.summary():find("Body  (summary: New gist)", 1, true), "summary() shows it")
end)

T.test("entries are coloured by kind through refreshes and reopening", function()
  AgentNotes.setup()
  AgentNotes.add { file = a, line = 1, text = "Selected" }
  AgentNotes.add { file = a, line = 1, kind = "warn", text = "Careful" }
  T.eq(fg "AgentNoteWarn", fg_of "Careful")
  AgentNotes.add { file = a, line = 2, kind = "issue", text = "Broken" }
  T.eq(fg "AgentNoteWarn", fg_of "Careful", "after a refresh")
  T.eq(fg "AgentNoteIssue", fg_of "Broken")
  vim.cmd "cclose"
  T.eq(fg "AgentNoteIssue", fg_of "Broken", "after reopening")
  cleanup()
end)

T.test("threads show a count, unread agent messages until the float shows them", function()
  AgentNotes.setup()
  AgentNotes.add { file = a, line = 3, text = "Other" }
  local id = AgentNotes.add { file = a, line = 1, text = "Why", channel = chan() }
  T.eq({ "1. ● Other", "2. ● Why" }, entries())
  AgentNotes.respond(id, "Because")
  AgentNotes.respond(id, "Also")
  T.eq({ "1. ● Other", "2. ● Why  [2 msgs, 2 new]" }, entries(), "list refreshed on reply")
  T.eq(2, AgentNotes.list()[2].unread)
  T.eq(fg "AgentNoteUnread", fg_of "[2 msgs")
  vim.cmd "wincmd p"
  vim.cmd.edit(a)
  api.nvim_win_set_cursor(0, { 1, 0 })
  AgentNotes.show()
  T.eq(0, AgentNotes.list()[2].unread, "read in the float")
  T.eq({ "1. ● Other", "2. ● Why  [2 msgs]" }, entries(), "list refreshed on read")
  T.eq(fg "Comment", fg_of "[2 msgs")
  cleanup()
end)

T.test("opening the chat reads the note's agent messages, and replies there arrive read", function()
  AgentNotes.setup()
  local id = AgentNotes.add { file = a, line = 1, text = "Why", channel = chan() }
  AgentNotes.respond(id, "Because")
  vim.cmd.edit(a)
  api.nvim_win_set_cursor(0, { 1, 0 })
  AgentNotes.reply()
  T.eq(0, AgentNotes.list()[1].unread, "read in the chat")
  AgentNotes.respond(id, "More")
  T.eq(0, AgentNotes.list()[1].unread, "shown in the open chat")
  T.eq(" Reply on note #1 · \\aR to view ", toast_text(), "no toast for the reply already on screen")
end)

T.test("a reply shows a toast that does not take focus, replaced by the next one", function()
  AgentNotes.setup()
  local one = AgentNotes.add { file = a, line = 1, text = "One", channel = chan() }
  local two = AgentNotes.add { file = a, line = 2, text = "Two", channel = chan() }
  local win = api.nvim_get_current_win()
  AgentNotes.respond(two, "hi")
  T.eq(" Reply on note #2 · \\aR to view ", toast_text())
  local t = AgentNotes._state.toast
  T.eq(win, api.nvim_get_current_win(), "focus stays")
  T.eq(false, api.nvim_win_get_config(t.win).focusable, "not focusable")
  AgentNotes.respond(one, "hello")
  T.eq(" 2 replies, latest on note #1 · \\aR to view ", toast_text())
  T.eq(t.win, AgentNotes._state.toast.win, "same window")
  AgentNotes._state.toast = nil
  api.nvim_win_close(t.win, true)
  AgentNotes.setup { keymaps = { lastreply = false }, toast = 50 }
  AgentNotes.respond(one, "again")
  T.eq(" Reply on note #1 ", toast_text(), "no key when unmapped")
  T.ok(vim.wait(1000, function() return AgentNotes._state.toast == nil end), "closes after toast ms")
  AgentNotes.setup { toast = false }
  AgentNotes.respond(one, "quiet")
  T.eq(nil, toast_text(), "toast = false")
  AgentNotes.setup()
end)

T.test("lastreply shows the note with the latest agent reply in its float", function()
  AgentNotes.setup { display = "inline" }
  vim.cmd "AgentNotes lastreply"
  T.eq("No agent reply yet", T.messages[#T.messages])
  local one = AgentNotes.add { file = a, line = 1, text = "One", channel = chan() }
  local two = AgentNotes.add { file = a, line = 3, text = "Two", channel = chan() }
  AgentNotes.respond(two, "first")
  AgentNotes.respond(one, "latest")
  vim.cmd "enew"
  vim.cmd "AgentNotes lastreply"
  T.eq({ a, 1 }, { api.nvim_buf_get_name(0), api.nvim_win_get_cursor(0)[1] })
  T.eq("One", float_lines()[1], "float opened")
  AgentNotes.clear()
  AgentNotes.setup { replies = false }
  vim.cmd "AgentNotes lastreply"
  T.ok(T.messages[#T.messages]:find("replies are off", 1, true), "gated on replies")
  AgentNotes.setup()
end)

T.run()
