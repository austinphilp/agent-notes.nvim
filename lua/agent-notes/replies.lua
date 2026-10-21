-- Two-way replies. An agent creates a channel (a JSONL file) and passes it to each
-- add() whose replies it wants. The user's replies and the agent's responses form each note's thread and
-- are appended to the channel file as {"type":"reply"|"response", ...} lines, so an
-- agent can watch the file for "reply" lines.
return function(C)
  local api = vim.api
  local R = {}
  local DIR = vim.fn.stdpath "state" .. "/agent-notes"
  local OFF = "AgentNotes: replies are off (setup option replies = false)"

  -- Resolves a channel id or path to its file, creating it unless create is false.
  function R.resolve(id, create)
    if type(id) ~= "string" or id == "" then error("AgentNotes: channel must be a non-empty string", 0) end
    local path
    if id:find "/" then
      path = vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(id), ":p"))
      -- Replies are appended to the file, so never accept a source file by mistake.
      if not path:match "%.jsonl$" then error("AgentNotes: a channel path must end in .jsonl: " .. id, 0) end
    else
      if not id:match "^[%w_.-]+$" then error("AgentNotes: channel ids use letters, digits, _ . - only: " .. id, 0) end
      path = DIR .. "/" .. id .. ".jsonl"
    end
    if create ~= false then
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local f = assert(io.open(path, "a"))
      f:close()
    end
    -- Resolve symlinks only once the file exists, so every call agrees.
    return C.abspath(path)
  end

  --- Creates a reply channel and prints and returns its path. Pass that path as
  --- `channel=` to add(); it is per call, so sessions sharing this nvim stay apart.
  --- id is a path (contains "/") or a name under stdpath('state')/agent-notes;
  --- without one, a new unique name is used.
  --- Raises while replies are off.
  function R.channel(id)
    if not C.S.config.replies then error(OFF, 0) end
    local path = R.resolve(id or ("%s-%04x"):format(os.date "%Y%m%d-%H%M%S", vim.fn.rand() % 0x10000))
    print(path)
    return path
  end

  local refresh_chat -- defined with the chat window below

  local function append(path, record)
    local f, err = io.open(path, "a")
    if not f then return vim.notify("AgentNotes: cannot write " .. path .. ": " .. err, vim.log.levels.ERROR) end
    f:write(vim.json.encode(record), "\n")
    f:close()
  end

  --- Adds a message to n's thread and, when n has a channel, to the channel file.
  function R.record(n, type, text)
    local time = os.date "!%Y-%m-%dT%H:%M:%SZ"
    n.thread = n.thread or {}
    n.thread[#n.thread + 1] = { who = type == "reply" and "you" or "agent", text = text, time = time }
    if C.S.chat and C.S.chat.note == n then refresh_chat() end
    if not n.channel then return end
    local line = C.range(n)
    append(n.channel, {
      type = type,
      note = n.id,
      order = C.position(n),
      file = n.path,
      line = line,
      excerpt = n.lines[1],
      text = text,
      time = time,
    })
  end

  -- The chat window for one note: a read-only history float (note text, then the
  -- thread) above a small input float. It stays open after sending, like a chat.
  function R.close_chat()
    local c = C.S.chat
    C.S.chat = nil
    if not c then return end
    pcall(api.nvim_del_augroup_by_name, "agent_notes_chat")
    -- Leave insert mode first, or the user's next keys would land in the source buffer.
    local cur = api.nvim_get_current_win()
    if cur == c.input or cur == c.history then vim.cmd "stopinsert" end
    for _, w in ipairs { c.input, c.history } do
      if api.nvim_win_is_valid(w) then api.nvim_win_close(w, true) end
    end
    if api.nvim_win_is_valid(c.src_win) then api.nvim_set_current_win(c.src_win) end
  end

  -- Redraws the history and scrolls it to the newest message.
  function R.refresh_chat() refresh_chat() end

  function refresh_chat()
    local c = C.S.chat
    if not (c and api.nvim_win_is_valid(c.history)) then return end
    local lines, marks = C.float.contents({ c.note }, false)
    if not c.note.thread or #c.note.thread == 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "No messages yet."
      marks[#marks + 1] = { row = #lines - 1, e = #lines[#lines], hl = "Comment" }
    end
    C.float.paint(c.history_buf, lines, marks)
    api.nvim_win_set_cursor(c.history, { #lines, 0 })
    api.nvim_win_call(c.history, function() vim.cmd "normal! zb" end)
    api.nvim_win_set_config(c.history, { title = (" Note %d/%d "):format(C.position(c.note), #C.S.notes) })
  end

  local function open_chat(n, src_win)
    R.close_chat()
    -- Fit the screen: borders take 4 rows, the cmdline and statusline 2 more.
    local width = math.max(20, math.min(100, vim.o.columns - 8))
    local height = math.max(4, math.min(36, vim.o.lines - 8))
    local input_h = height >= 12 and 4 or 2
    local history_h = height - input_h - 2
    local row = math.floor((vim.o.lines - height - 2) / 2)
    local col = math.floor((vim.o.columns - width - 2) / 2)
    local hl = C.KINDS[n.kind].hl
    local history_buf = api.nvim_create_buf(false, true)
    vim.bo[history_buf].bufhidden = "wipe"
    local history = api.nvim_open_win(history_buf, false, {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = history_h,
      border = "rounded",
      style = "minimal",
      title = " Note ",
      title_pos = "left",
    })
    local input_buf = api.nvim_create_buf(false, true)
    vim.bo[input_buf].bufhidden = "wipe"
    local input = api.nvim_open_win(input_buf, true, {
      relative = "editor",
      row = row + history_h + 2,
      col = col,
      width = width,
      height = input_h,
      border = "rounded",
      style = "minimal",
      title = " Reply ",
      footer = " <C-CR>/<C-s> send · q/<Esc> close ",
      footer_pos = "right",
    })
    for _, w in ipairs { history, input } do
      vim.wo[w].winhighlight = "FloatBorder:" .. hl .. ",FloatTitle:" .. hl
      vim.wo[w].wrap, vim.wo[w].linebreak, vim.wo[w].breakindent = true, true, true
    end
    C.S.chat = { note = n, history = history, history_buf = history_buf, input = input, src_win = src_win }
    refresh_chat()

    local function send()
      local text = vim.trim(table.concat(api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"))
      if text == "" then return end
      api.nvim_buf_set_lines(input_buf, 0, -1, false, {})
      R.record(n, "reply", text)
    end
    local function close()
      vim.cmd "stopinsert"
      R.close_chat()
    end
    for _, key in ipairs { "<C-CR>", "<C-s>" } do
      vim.keymap.set({ "n", "i" }, key, send, { buffer = input_buf, desc = "Send reply" })
    end
    for _, b in ipairs { input_buf, history_buf } do
      vim.keymap.set("n", "q", close, { buffer = b, desc = "Close chat" })
      vim.keymap.set("n", "<Esc>", close, { buffer = b, desc = "Close chat" })
    end
    -- Closing either window by other means closes the pair.
    api.nvim_create_autocmd("WinClosed", {
      group = api.nvim_create_augroup("agent_notes_chat", { clear = true }),
      pattern = { tostring(history), tostring(input) },
      callback = function() vim.schedule(R.close_chat) end,
    })
    vim.cmd "startinsert"
  end

  --- Starts a reply to the note in the focused float or on the cursor line.
  function R.reply()
    if not C.S.config.replies then return vim.notify(OFF, vim.log.levels.WARN) end
    local f = C.S.float
    local in_float = f and api.nvim_get_current_win() == f.win
    local notes = in_float and f.notes or C.notes_at_cursor()
    local src_win = in_float and f.src_win or api.nvim_get_current_win()
    if #notes == 0 then return print "No agent note on this line" end
    local function start(n)
      if not n then return end
      if not n.channel then
        return vim.notify("AgentNotes: the agent is not listening for replies to this note", vim.log.levels.WARN)
      end
      C.close_float()
      if api.nvim_win_is_valid(src_win) then api.nvim_set_current_win(src_win) end
      open_chat(n, api.nvim_get_current_win())
    end
    if #notes == 1 then return start(notes[1]) end
    vim.ui.select(notes, { prompt = "Reply to", format_item = function(n) return n.lines[1] end }, start)
  end

  --- Prints and returns the user's replies in reading order, one per line; with a
  --- channel, only replies to that channel's notes.
  function R.replies(channel)
    local path = channel and R.resolve(channel, false)
    local out = {}
    for _, n in ipairs(C.ordered()) do
      for _, m in ipairs((not path or n.channel == path) and n.thread or {}) do
        if m.who == "you" then
          out[#out + 1] = ("note %d (#%d) %s:%d: %s"):format(C.position(n), n.id, C.rel(n.path), (C.range(n)), m.text)
        end
      end
    end
    local s = #out > 0 and table.concat(out, "\n") or "No replies"
    print(s)
    return s
  end

  return R
end
