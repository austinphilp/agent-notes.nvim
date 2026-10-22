-- Which notes the user has viewed, so the agent does not assume every note was read.
-- A note counts as viewed when, with a UI attached, the user lands on it (stepping,
-- the notes list or a link), sees it in the note float or the chat, or rests the
-- cursor for DWELL ms on its lines while its inline text is on screen, or while
-- its float is open. The first
-- view of a note with a channel appends a {"type":"view"} line to the channel file.
return function(C)
  local api = vim.api
  local S = C.S
  local V = {}

  V.DWELL = 1000

  -- An agent drives a headless session before the user attaches; nothing it shows
  -- then has been seen.
  local function watched() return #api.nvim_list_uis() > 0 end

  --- Records a view of each note now.
  function V.mark(notes)
    if not watched() then return end
    local time = os.date "!%Y-%m-%dT%H:%M:%SZ"
    for _, n in ipairs(notes) do
      if vim.tbl_contains(S.notes, n) then
        if not n.viewed then
          n.viewed, n.first_viewed = true, time
          C.replies.log(n, "view", { time = time })
        end
        n.last_viewed = time
      end
    end
  end

  --- Records a view of the notes on the cursor line, after landing there.
  function V.at_cursor() V.mark(C.notes_at_cursor()) end

  -- The cursor has rested: count the notes in an open float, which may have
  -- opened before the user attached, and the notes on the cursor line whose text
  -- shows inline, under a first line that is on screen.
  local function rest()
    if not watched() then return end
    local f = S.float
    if f and api.nvim_win_is_valid(f.win) then V.mark(f.notes) end
    if not S.inline or api.nvim_win_get_config(0).relative ~= "" or vim.bo.buftype ~= "" then return end
    local top, bottom = vim.fn.line "w0", vim.fn.line "w$"
    local seen = {}
    for _, n in ipairs(C.notes_at_cursor()) do
      local l = C.range(n)
      if l >= top and l <= bottom then seen[#seen + 1] = n end
    end
    V.mark(seen)
  end

  -- On each cursor move: a new notes-list selection is a landing, and the rest
  -- timer starts over. The timer lives in S so a reload reuses it.
  local function moved()
    if #S.notes == 0 then return end
    local n = C.qf_selected()
    if n then V.mark { n } end
    S.rest_timer = S.rest_timer or vim.uv.new_timer()
    S.rest_timer:stop()
    S.rest_timer:start(V.DWELL, 0, vim.schedule_wrap(rest))
  end

  -- UIEnter: the user attaching to a session where the cursor already sits on a note.
  api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "UIEnter" }, {
    group = api.nvim_create_augroup("agent_notes_viewed", { clear = true }),
    callback = moved,
  })

  --- Prints and returns the viewed and unviewed note ids, each in reading order.
  function V.report()
    local out = { viewed = {}, unviewed = {} }
    for _, n in ipairs(C.ordered()) do
      table.insert(n.viewed and out.viewed or out.unviewed, n.id)
    end
    if #S.notes == 0 then
      print "No agent notes"
      return out
    end
    local function ids(list)
      return #list > 0 and table.concat(vim.tbl_map(function(id) return "#" .. id end, list), " ") or "none"
    end
    print(("viewed: %s\nunviewed: %s"):format(ids(out.viewed), ids(out.unviewed)))
    return out
  end

  return V
end
