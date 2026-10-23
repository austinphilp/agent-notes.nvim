local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local api = vim.api
local ns = api.nvim_create_namespace "agent_notes"
local md = require "agent-notes.markdown"()
local a = T.file("a.lua", { "one", "two", "three" })
local b = T.file("b.lua", { "x", "y", "z" })

-- Renders one line with no links and returns its text and {text, hl} per mark.
local function one(line)
  local lines, marks = md.render({ line }, {})
  local got = {}
  for _, m in ipairs(marks) do
    got[#got + 1] = { lines[m.row]:sub(m.s + 1, m.e), m.hl }
  end
  return lines[1], got
end

T.test("inline markup drops its markers and marks the text", function()
  local text, marks = one "**b** __b2__ *i* _i2_ ~~s~~ `c`"
  T.eq("b b2 i i2 s c", text)
  T.eq({
    { "c", "AgentNoteCode" },
    { "b", "AgentNoteBold" },
    { "b2", "AgentNoteBold" },
    { "i", "AgentNoteItalic" },
    { "i2", "AgentNoteItalic" },
    { "s", "AgentNoteStrike" },
  }, marks)
  T.eq({ "a bold x", { { "x", "AgentNoteItalic" }, { "bold x", "AgentNoteBold" } } }, { one "a **bold *x***" })
end)

T.test("text that is not markup stays as written", function()
  for _, line in ipairs {
    "plain text, nothing (here) [x] 1. 2 # 3",
    "snake_case_name, _private_var and foo__bar__baz",
    "a * b, 2*3 and 4 * 5 * 6",
    "*args and **kwargs",
    "**unclosed and *also and `tick",
    "",
  } do
    T.eq({ line, {} }, { one(line) }, line)
  end
end)

T.test("many unmatched markers render in linear time", function()
  local line = ("*a _b ~~c **d "):rep(300)
  local start = vim.uv.hrtime()
  T.eq({ line, {} }, { one(line) })
  T.ok(vim.uv.hrtime() - start < 1e9, "under a second")
end)

T.test("links keep their columns after bullet and quote prefixes and next to _", function()
  -- "‹a›" is 9 bytes: two 3-byte marks around a 3-byte label.
  local src = { "- ‹aaa› x", "  > ‹bbb›", "x ‹ccc›_i_ _‹ddd›_" }
  local spans = {
    { row = 1, s = 2, e = 11, link = 1 },
    { row = 2, s = 4, e = 13, link = 2 },
    { row = 3, s = 2, e = 11, link = 3 },
    { row = 3, s = 16, e = 25, link = 4 },
  }
  local lines, marks, moved = md.render(src, spans)
  T.eq({ "• ‹aaa› x", "  │ ‹bbb›", "x ‹ccc›i ‹ddd›" }, lines)
  local shown = {}
  for _, s in ipairs(moved) do
    shown[#shown + 1] = { s.link, lines[s.row]:sub(s.s + 1, s.e) }
  end
  T.eq({ { 1, "‹aaa›" }, { 2, "‹bbb›" }, { 3, "‹ccc›" }, { 4, "‹ddd›" } }, shown)
  T.eq({ "i", "‹ddd›" }, { lines[3]:sub(marks[2].s + 1, marks[2].e), lines[3]:sub(marks[3].s + 1, marks[3].e) })
end)

T.test("code spans bind before emphasis, and links keep their columns in code blocks", function()
  T.eq({ "a b* c", { { "b*", "AgentNoteCode" }, { "a b* c", "AgentNoteItalic" } } }, { one "*a `b*` c*" })
  local lines, _, spans = md.render({ "```", "x ‹y›" }, { { row = 2, s = 2, e = 9, link = 1 } })
  T.eq({ { "x ‹y›" }, { { row = 1, s = 2, e = 9, link = 1 } } }, { lines, spans })
end)

T.test("code spans keep their contents as written", function()
  T.eq({ "x **y** _z_ a`b", { { "**y** _z_", "AgentNoteCode" }, { "a`b", "AgentNoteCode" } } }, {
    one "x `**y** _z_` `` a`b ``",
  })
end)

T.test("headings, bullets, quotes and numbered lists", function()
  local src = { "# Top **b**", "###### Six", "- one", "  * two", "+ three", "1. four", "> q", "> > qq" }
  local lines, marks = md.render(src, {})
  T.eq({ "Top b", "Six", "• one", "  • two", "• three", "1. four", "│ q", "│ │ qq" }, lines)
  T.eq({
    { row = 1, s = 0, e = 5, hl = "AgentNoteHeading" },
    { row = 1, s = 4, e = 5, hl = "AgentNoteBold" },
    { row = 2, s = 0, e = 3, hl = "AgentNoteHeading" },
    { row = 7, s = 0, e = #"│ q", hl = "AgentNoteQuote" },
    { row = 8, s = 0, e = #"│ │ qq", hl = "AgentNoteQuote" },
  }, marks)
  T.eq({ "####### seven", "#tag" }, (md.render({ "####### seven", "#tag" }, {})), "not headings")
end)

T.test("fenced code blocks hide the fences and keep the code as written", function()
  local src = { "before", "```lua", "x = **y** -- _z_", "- no", "```", "~~~", "`a`", "~~~", "after" }
  local lines, marks = md.render(src, {})
  T.eq({ "before", "x = **y** -- _z_", "- no", "`a`", "after" }, lines)
  T.eq({
    { row = 2, s = 0, e = 16, hl = "AgentNoteCode" },
    { row = 3, s = 0, e = 4, hl = "AgentNoteCode" },
    { row = 4, s = 0, e = 3, hl = "AgentNoteCode" },
  }, marks)
  T.eq({ "code", "**to the end**" }, (md.render({ "```", "code", "**to the end**" }, {})), "unclosed fence")
end)

-- Opens the float on note id's first line and returns its buffer.
local function float_of(file, line)
  vim.cmd.edit(file)
  api.nvim_win_set_cursor(0, { line, 0 })
  AgentNotes.show()
  local f = AgentNotes._state.float
  T.ok(f, "float open")
  return api.nvim_win_get_buf(f.win), f
end

-- The text and highlight of each mark in buf, in order.
local function hl_marks(buf)
  local lines, out = api.nvim_buf_get_lines(buf, 0, -1, false), {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local d = m[4]
    if d.hl_group then out[#out + 1] = { m[2], lines[m[2] + 1]:sub(m[3] + 1, d.end_col), d.hl_group } end
  end
  return out
end

T.test("the float shows markdown with links in the right place, and <CR> follows them", function()
  AgentNotes.setup { display = "float" }
  AgentNotes.add { file = a, line = 2, text = "**See [[" .. b .. ":3|z]]** and `[[" .. b .. ":2|y]]`" }
  local buf, f = float_of(a, 2)
  T.eq("See ‹z› and ‹y›", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  T.eq({
    { 0, "See ‹z›", "AgentNoteBold" },
    { 0, "‹z›", "Underlined" },
    { 0, "‹y›", "AgentNoteCode" },
    { 0, "‹y›", "Underlined" },
    { 2, "<CR> follow link", "Comment" },
  }, hl_marks(buf))
  local line = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  api.nvim_set_current_win(f.win)
  api.nvim_win_set_cursor(f.win, { 1, line:find "‹y" - 1 })
  api.nvim_feedkeys(vim.keycode "<CR>", "x", false)
  T.eq({ b, 2 }, { api.nvim_buf_get_name(0), api.nvim_win_get_cursor(0)[1] }, "followed the second link")
end)

T.test("the float's width fits the shown text, not the markers", function()
  AgentNotes.setup { display = "float" }
  AgentNotes.add { file = a, line = 1, text = "**" .. ("x"):rep(30) .. "**" }
  local _, f = float_of(a, 1)
  -- 30 cells of text plus the 2-cell kind bar.
  T.eq(32, api.nvim_win_get_width(f.win))
end)

T.test("plain note text shows as before", function()
  AgentNotes.setup { display = "float" }
  AgentNotes.add { file = a, line = 3, text = "Plain snake_case text.\nSecond line, 2 * 3." }
  local buf = float_of(a, 3)
  T.eq({ "Plain snake_case text.", "Second line, 2 * 3." }, api.nvim_buf_get_lines(buf, 0, -1, false))
  T.eq({}, hl_marks(buf))
end)

T.test("the chat shows the note and its thread as markdown", function()
  AgentNotes.setup { display = "inline" }
  local id = AgentNotes.add { file = a, line = 1, text = "# Why", channel = AgentNotes.channel "md" }
  AgentNotes.respond(id, "Because `x_y`:\n- **one**")
  vim.cmd.edit(a)
  api.nvim_win_set_cursor(0, { 1, 0 })
  AgentNotes.reply()
  local chat = AgentNotes._state.chat
  T.ok(chat, "chat open")
  local buf = api.nvim_win_get_buf(chat.history)
  T.eq({ "Why", "", "agent:", "Because x_y:", "• one" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  T.eq({
    { 0, "Why", "AgentNoteHeading" },
    { 2, "agent:", "AgentNoteInfo" },
    { 3, "x_y", "AgentNoteCode" },
    { 4, "one", "AgentNoteBold" },
  }, hl_marks(buf))
end)

T.run()
