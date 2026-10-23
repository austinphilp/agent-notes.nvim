-- The note float: note text (kind shown by colour only) and its reply thread as
-- basic markdown, and links that <CR> follows. It closes when the cursor leaves
-- the notes' lines.
return function(C)
  local api = vim.api
  local F = {}

  function F.close()
    local f = C.S.float
    C.S.float = nil
    pcall(api.nvim_del_augroup_by_name, "agent_notes_float")
    if f and api.nvim_win_is_valid(f.win) then api.nvim_win_close(f.win, true) end
    return f
  end

  function F.follow_here()
    local f = C.S.float
    local row, col = unpack(api.nvim_win_get_cursor(f.win))
    for _, s in ipairs(f.spans) do
      if s.row == row - 1 and col >= s.s and col < s.e then return C.follow_link(s.link) end
    end
    C.pick(f.links)
  end

  -- Builds the lines for notes and their threads plus highlight marks and link
  -- spans; hints = false leaves out the key hints line.
  function F.contents(notes, hints)
    local lines, marks, spans, links = {}, {}, {}, {}
    local function add(text, hl)
      for piece in (text .. "\n"):gmatch "(.-)\n" do
        lines[#lines + 1] = piece
        if hl then marks[#marks + 1] = { row = #lines - 1, e = #piece, hl = hl } end
      end
    end
    -- Adds markdown text, with bar's kind bar on each line; returns its moved spans.
    local function add_markdown(text_lines, text_spans, bar)
      local base = #lines
      local shown, styled, moved = C.markdown.render(text_lines, text_spans)
      for _, l in ipairs(shown) do
        lines[#lines + 1] = l
        if bar then marks[#marks + 1] = { row = #lines - 1, bar = bar } end
      end
      for _, m in ipairs(styled) do
        marks[#marks + 1] = { row = base + m.row - 1, s = m.s, e = m.e, hl = m.hl }
      end
      for _, s in ipairs(moved) do
        s.row = base + s.row - 1
      end
      return moved
    end
    for i, n in ipairs(notes) do
      if i > 1 then lines[#lines + 1] = "" end
      for _, s in ipairs(add_markdown(n.lines, n.spans, C.KINDS[n.kind].hl)) do
        local link = n.links[s.link]
        links[#links + 1] = link
        spans[#spans + 1] = { row = s.row, s = s.s, e = s.e, link = link }
        marks[#marks + 1] = { row = s.row, s = s.s, e = s.e, hl = "Underlined" }
      end
      for _, m in ipairs(n.thread or {}) do
        lines[#lines + 1] = ""
        add(m.who .. ":", m.who == "you" and "AgentNoteYou" or C.KINDS[n.kind].hl)
        add_markdown(vim.split(m.text, "\n", { plain = true }))
      end
    end
    local keys = {}
    if #links > 0 then keys[#keys + 1] = "<CR> follow link" end
    for _, n in ipairs(notes) do
      if n.channel and C.S.config.replies then
        local key = C.config.key_for "reply"
        keys[#keys + 1] = key and key .. " reply" or ":AgentNotes reply"
        break
      end
    end
    if hints ~= false and #keys > 0 then
      lines[#lines + 1] = ""
      add(table.concat(keys, " · "), "Comment")
    end
    return lines, marks, spans, links
  end

  -- Replaces buf's text with lines and applies marks from F.contents.
  function F.paint(buf, lines, marks)
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(buf, C.ns, 0, -1)
    for _, m in ipairs(marks) do
      if m.bar then
        api.nvim_buf_set_extmark(buf, C.ns, m.row, 0, { virt_text = { { "▍ ", m.bar } }, virt_text_pos = "inline" })
      else
        api.nvim_buf_set_extmark(buf, C.ns, m.row, m.s or 0, { end_col = m.e, hl_group = m.hl })
      end
    end
    vim.bo[buf].modifiable = false
  end

  -- Opens a float for notes below the cursor; focus enters it.
  function F.open(notes, focus)
    F.close()
    local lines, marks, spans, links = F.contents(notes)
    local buf = api.nvim_create_buf(false, true)
    F.paint(buf, lines, marks)
    vim.bo[buf].bufhidden = "wipe"
    local width = 20
    for _, l in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
    end
    width = math.min(width, 82, math.max(20, vim.o.columns - 8))
    local height = 0
    for _, l in ipairs(lines) do
      height = height + math.max(1, math.ceil((vim.fn.strdisplaywidth(l) + 2) / width))
    end
    local first, last = math.huge, 0
    for _, n in ipairs(notes) do
      local l, e = C.range(n)
      first, last = math.min(first, l), math.max(last, e)
    end
    local hl = C.KINDS[notes[1].kind].hl
    local src_win, src_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    local win = api.nvim_open_win(buf, false, {
      relative = "cursor",
      row = 1,
      col = 0,
      width = width,
      height = math.min(height, 20, math.max(1, vim.o.lines - 6)),
      style = "minimal",
      border = "rounded",
      title = (" %d/%d "):format(C.position(notes[1]), #C.S.notes),
      title_pos = "right",
    })
    vim.wo[win].winhighlight = "FloatBorder:" .. hl .. ",FloatTitle:" .. hl
    vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].breakindent = true, true, true
    -- The estimate above ignores word wrapping; size to the real wrapped height.
    -- Keep the annotated line visible: open below the cursor, or above it when
    -- there is clearly more room there, and cap the height to that space.
    local wrapped = api.nvim_win_text_height(win, {}).all
    local row = vim.fn.screenpos(src_win, api.nvim_win_get_cursor(src_win)[1], 1).row
    local below = vim.o.lines - vim.o.cmdheight - 1 - row - 2
    local above = row - 1 - 2 - (vim.o.showtabline > 0 and 1 or 0)
    local up = row > 0 and below < wrapped and above > below
    local height = math.max(1, math.min(wrapped, up and above or below))
    local config = { relative = "cursor", row = up and 0 or 1, col = 0, anchor = up and "SW" or "NW", height = height }
    if height < wrapped then
      local key = C.config.key_for "enter" or ":AgentNotes enter"
      config.footer, config.footer_pos = (" more: %s to scroll "):format(key), "right"
    end
    api.nvim_win_set_config(win, config)
    C.S.float = { win = win, src_win = src_win, notes = notes, spans = spans, links = links }
    vim.keymap.set("n", "<CR>", F.follow_here, { buffer = buf, desc = "Follow note link" })
    vim.keymap.set("n", "q", F.close, { buffer = buf, desc = "Close note" })
    local group = api.nvim_create_augroup("agent_notes_float", { clear = true })
    -- A resize can clip the float's wrapped text; close it rather than show it cut.
    api.nvim_create_autocmd("VimResized", { group = group, callback = F.close })
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter", "WinEnter" }, {
      group = group,
      callback = function()
        local cur = api.nvim_get_current_win()
        if not api.nvim_win_is_valid(win) then return true end
        if cur == win then return end
        local row = api.nvim_win_get_cursor(cur)[1]
        if cur ~= src_win or api.nvim_get_current_buf() ~= src_buf or row < first or row > last then F.close() end
      end,
    })
    if focus then api.nvim_set_current_win(win) end
    C.viewed.mark(notes)
    C.viewed.read(notes)
  end

  return F
end
