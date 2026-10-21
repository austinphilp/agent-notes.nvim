local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local api = vim.api
local a = T.file("a.lua", { "one", "two" })

local DEFAULTS = {
  socket = false,
  display = "both",
  replies = true,
  highlights = {},
  keymaps = {
    next = "<Leader>an",
    prev = "<Leader>ap",
    list = "<Leader>al",
    show = "<Leader>as",
    enter = "<Leader>ae",
    follow = "<Leader>ag",
    reply = "<Leader>ar",
    autofloat = "<Leader>af",
    inline = "<Leader>ai",
  },
}

local LINKS = {
  AgentNoteInfo = "DiagnosticInfo",
  AgentNoteWarn = "DiagnosticWarn",
  AgentNoteIssue = "DiagnosticError",
  AgentNoteYou = "DiagnosticOk",
  AgentNoteStep = "Comment",
}

local function hl(name) return api.nvim_get_hl(0, { name = name }) end

T.test("config() returns the defaults before setup and a copy", function()
  T.eq(DEFAULTS, AgentNotes.config())
  AgentNotes.config().replies = false
  T.eq(true, AgentNotes.config().replies, "copy")
end)

T.test("config() reflects setup options merged over the defaults", function()
  AgentNotes.setup { display = "float", keymaps = { next = "]n", reply = false } }
  local cfg = AgentNotes.config()
  T.eq("float", cfg.display)
  T.eq("]n", cfg.keymaps.next)
  T.eq(false, cfg.keymaps.reply)
  T.eq("<Leader>ap", cfg.keymaps.prev)
  AgentNotes.setup()
  T.eq(DEFAULTS, AgentNotes.config(), "setup() again restores the defaults")
end)

T.test("bad options raise a clear error and change nothing", function()
  AgentNotes.setup { display = "inline" }
  for needle, opts in pairs {
    ['display must be "both", "inline" or "float", got "side"'] = { display = "side" },
    ["display must be"] = { display = 1 },
    ["opts must be a table, got string"] = "inline",
    ["replies must be a boolean, got number"] = { replies = 0 },
    ["highlights must be a table, got string"] = { highlights = "red" },
    ["highlights.info must be a table, got string"] = { highlights = { info = "red" } },
    ["highlights.warn: "] = { highlights = { warn = { fg = "notacolour" } } },
    ["keymaps must be a table, got boolean"] = { keymaps = true },
    ["keymaps.next must be a key string or false, got true"] = { keymaps = { next = true } },
    ['keymaps.next must be a key string or false, got ""'] = { keymaps = { next = "" } },
    ["keymaps.inline: "] = { display = "float", keymaps = { inline = ("x"):rep(80) } },
    ["keymaps.next: a <Plug> map cannot be a key"] = { keymaps = { next = "<Plug>(AgentNotesNext)" } },
  } do
    T.raises("AgentNotes.setup: " .. needle, function() AgentNotes.setup(opts) end)
  end
  T.eq("inline", AgentNotes.config().display, "unchanged")
  T.eq(false, AgentNotes._state.autofloat, "display toggles unchanged")
  T.eq("<Plug>(AgentNotesInline)", vim.fn.maparg("<Leader>ai", "n"), "keys unchanged")
  local before = vim.tbl_map(hl, { "AgentNoteInfo", "AgentNoteWarn" })
  T.raises(
    "highlights.warn",
    function() AgentNotes.setup { highlights = { info = { fg = "#111111" }, warn = { fg = "notacolour" } } } end
  )
  T.eq(before, vim.tbl_map(hl, { "AgentNoteInfo", "AgentNoteWarn" }), "highlights unchanged")
end)

T.test("unknown keys warn and are ignored", function()
  T.messages = {}
  AgentNotes.setup { colour = 1, highlights = { hint = {} }, keymaps = { quit = "q" } }
  T.eq({
    "AgentNotes.setup: unknown option colour",
    "AgentNotes.setup: unknown option highlights.hint",
    "AgentNotes.setup: unknown option keymaps.quit",
  }, T.messages)
  T.eq(DEFAULTS, AgentNotes.config())
end)

T.test("highlight groups link to diagnostic colours by default", function()
  AgentNotes.setup()
  for name, link in pairs(LINKS) do
    T.eq(link, hl(name).link, name)
  end
end)

T.test("highlights options override the groups and survive :colorscheme", function()
  AgentNotes.setup { highlights = { info = { fg = "#123456" }, step = { link = "Title" } } }
  local function check(when)
    T.eq(0x123456, hl("AgentNoteInfo").fg, "info " .. when)
    T.eq("Title", hl("AgentNoteStep").link, "step " .. when)
    T.eq("DiagnosticWarn", hl("AgentNoteWarn").link, "warn " .. when)
  end
  check "after setup"
  vim.cmd.colorscheme "default"
  check "after :colorscheme"
  AgentNotes.setup()
  T.eq({ link = "DiagnosticInfo" }, hl "AgentNoteInfo", "dropped by a later setup")
  T.eq({ link = "Comment" }, hl "AgentNoteStep", "link dropped by a later setup")
  vim.cmd.colorscheme "default"
  T.eq("DiagnosticInfo", hl("AgentNoteInfo").link, "and after :colorscheme")
end)

T.test("the user's own :hi wins over the default links", function()
  AgentNotes.setup()
  vim.cmd "hi AgentNoteWarn guifg=#654321"
  AgentNotes.setup()
  T.eq(0x654321, hl("AgentNoteWarn").fg, "after setup")
  -- A colourscheme clears :hi groups; a ColorScheme autocmd of the user's restores it.
  local group = api.nvim_create_augroup("user_colours", {})
  api.nvim_create_autocmd("ColorScheme", { group = group, command = "hi AgentNoteWarn guifg=#654321" })
  vim.cmd.colorscheme "default"
  T.eq(0x654321, hl("AgentNoteWarn").fg, "after :colorscheme")
  vim.cmd "hi clear AgentNoteWarn"
  api.nvim_del_augroup_by_id(group)
  AgentNotes.setup()
end)

T.test("replies off disables replying but keeps notes", function()
  AgentNotes.setup()
  local channel = AgentNotes.channel "off"
  AgentNotes.setup { replies = false }
  T.raises("replies are off", function() AgentNotes.channel "off2" end)
  T.ok(not vim.uv.fs_stat(vim.fn.stdpath "state" .. "/agent-notes/off2.jsonl"), "no channel file")
  local id = AgentNotes.add { file = a, line = 1, text = "no replies", channel = channel }
  T.eq({ id }, vim.tbl_map(function(n) return n.id end, AgentNotes.list()), "note added")

  T.messages = {}
  vim.cmd.edit(a)
  AgentNotes.reply()
  T.ok(T.messages[1]:find("replies are off", 1, true), T.messages[1])
  T.ok(AgentNotes._state.chat == nil, "no chat")
  vim.cmd "AgentNotes reply"
  T.ok(T.messages[2]:find("replies are off", 1, true), ":AgentNotes reply")
  vim.cmd "AgentNotes replies"
  T.ok(T.messages[3]:find("replies are off", 1, true), ":AgentNotes replies")
  local actions = vim.fn.getcompletion("AgentNotes ", "cmdline")
  T.ok(not vim.tbl_contains(actions, "reply") and not vim.tbl_contains(actions, "replies"), "not completed")

  AgentNotes.respond(id, "still shown")
  T.eq("still shown", AgentNotes.list()[1].thread[1].text, "respond threads the answer")
  T.eq({}, vim.fn.readfile(channel), "nothing written to the channel")
  AgentNotes.setup()
end)

T.test("replies off keeps an open chat and its draft, and hides the reply hint", function()
  AgentNotes.setup()
  vim.cmd.edit(a)
  AgentNotes.add { file = a, line = 1, text = "chat", channel = AgentNotes.channel "hint" }
  AgentNotes.show()
  local function float_text()
    return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(AgentNotes._state.float.win), 0, -1, false), "\n")
  end
  T.ok(float_text():find("\\ar reply", 1, true), float_text())
  AgentNotes.show()
  AgentNotes.setup { keymaps = { reply = "<C-r>" } }
  AgentNotes.show()
  T.ok(float_text():find("<C-R> reply", 1, true), "remapped hint: " .. float_text())
  AgentNotes.show()
  AgentNotes.setup { keymaps = false }
  AgentNotes.show()
  T.ok(
    float_text():find("· :AgentNotes reply\n", 1, true) or float_text():match ":AgentNotes reply$",
    "command hint: " .. float_text()
  )
  AgentNotes.show()
  AgentNotes.setup()
  AgentNotes.reply()
  T.ok(AgentNotes._state.chat ~= nil, "chat open")
  vim.cmd "stopinsert"
  local chat = AgentNotes._state.chat
  api.nvim_buf_set_lines(api.nvim_win_get_buf(chat.input), 0, -1, false, { "draft" })
  AgentNotes.setup { replies = false }
  T.ok(api.nvim_win_is_valid(chat.input), "chat stays open")
  T.eq({ "draft" }, api.nvim_buf_get_lines(api.nvim_win_get_buf(chat.input), 0, -1, false), "draft kept")
  api.nvim_win_close(chat.input, true)
  T.ok(vim.wait(1000, function() return AgentNotes._state.chat == nil end), "chat closed")
  AgentNotes.show()
  T.ok(not float_text():find("reply", 1, true), "no reply hint: " .. float_text())
  AgentNotes.show()
  AgentNotes.setup()
end)

T.run()
