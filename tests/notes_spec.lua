local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local a = T.file("a.lua", { "local x = 1", "local y = 2", "return x + y" })
local b = T.file("b.lua", { "print(1)", "print(2)" })

T.test("add returns ids and summary lists notes in reading order", function()
  local first = AgentNotes.add { file = a, line = 2, end_line = 3, kind = "warn", text = "Second\nmore" }
  local second = AgentNotes.add { file = b, line = 1, text = "See [[" .. a .. ":1|the start]]", order = 0 }
  T.ok(second == first + 1, "ids increase")
  T.eq(
    ("1. #%d [info] [unviewed] %s:1  See ‹the start›  (links: the start -> %s:1)\n2. #%d [warn] [unviewed] %s:2-3  Second"):format(
      second,
      b,
      vim.fn.fnamemodify(a, ":~:."),
      first,
      a
    ),
    AgentNotes.summary(),
    "summary"
  )
  T.eq({ second, first }, vim.tbl_map(function(n) return n.id end, AgentNotes.list()), "list order")
end)

T.test("adding the same note twice keeps one", function()
  local id = AgentNotes.add { file = a, line = 1, text = "same" }
  T.eq(id, AgentNotes.add { file = a, line = 1, text = "same", order = vim.NIL })
  T.eq(1, #AgentNotes.list())
end)

T.test("notes render as a sign and virtual lines without changing the file", function()
  AgentNotes.add { file = a, line = 1, kind = "issue", text = "Broken" }
  local buf = vim.fn.bufadd(a)
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace "agent_notes", 0, -1, { details = true })
  T.eq(1, #marks, "one extmark")
  T.eq("■ ", marks[1][4].sign_text, "sign")
  T.eq("AgentNoteIssue", marks[1][4].sign_hl_group, "sign highlight")
  T.eq("Broken", marks[1][4].virt_lines[1][3][1], "virtual text")
  T.eq({ "local x = 1", "local y = 2", "return x + y" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  T.ok(not vim.bo[buf].modified, "buffer unmodified")
end)

T.test("a bad note raises and adds nothing", function()
  T.raises("kind must be info, warn or issue", function() AgentNotes.add { file = a, line = 1, kind = "x", text = "t" } end)
  T.raises("has 3 lines, got 4", function() AgentNotes.add { file = a, line = 4, text = "t" } end)
  T.raises("link target not found", function() AgentNotes.add { file = a, line = 1, text = "[[/nope.lua:1]]" } end)
  T.eq(0, #AgentNotes.list())
  T.eq("No agent notes", AgentNotes.summary())
end)

T.test("clear removes all notes, a file's, or a channel's, and returns the count", function()
  local channel = AgentNotes.channel "spec"
  T.eq(vim.uv.fs_realpath(vim.fn.stdpath "state") .. "/agent-notes/spec.jsonl", channel, "channel path")
  AgentNotes.add { file = a, line = 1, text = "a1", channel = channel }
  AgentNotes.add { file = a, line = 2, text = "a2" }
  AgentNotes.add { file = b, line = 1, text = "b1", channel = channel }
  AgentNotes.add { file = b, line = 2, text = "b2" }
  T.eq(2, AgentNotes.clear { channel = channel })
  T.eq(1, AgentNotes.clear(b))
  T.eq(1, AgentNotes.clear())
  T.eq(0, #AgentNotes.list())
end)

T.test("respond threads the answer and appends it to the channel file", function()
  local channel = AgentNotes.channel "respond"
  local id = AgentNotes.add { file = a, line = 1, text = "Why?", channel = channel }
  AgentNotes.respond(id, "Because.")
  T.eq("agent", AgentNotes.list()[1].thread[1].who)
  local record = vim.json.decode(vim.fn.readfile(channel)[1])
  T.eq({ "response", id, "Because." }, { record.type, record.note, record.text })
end)

T.run()
