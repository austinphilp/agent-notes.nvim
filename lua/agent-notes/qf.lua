-- The notes list's entry text and colours. Each entry reads "path|lines| N. ● text"
-- plus a thread tag, coloured by kind. A decoration provider colours the entries
-- as they are drawn, so the colours survive list refreshes, :colder and :copen.
return function(C)
  local api = vim.api
  local S = C.S
  local Q = {}

  --- "  [3 msgs]", or "  [3 msgs, 1 new]" with unread agent messages; "" without a thread.
  function Q.tag(n)
    local count, unread = #(n.thread or {}), n.unread or 0
    if count == 0 then return "" end
    local msgs = ("%d msg%s"):format(count, count == 1 and "" or "s")
    return unread > 0 and ("  [%s, %d new]"):format(msgs, unread) or ("  [%s]"):format(msgs)
  end

  --- The note's summary or first line, as list_text picks, falling back to the
  --- first line when the note has no summary.
  function Q.text(n) return S.config.list_text == "summary" and n.summary or n.lines[1] end

  --- An entry's text after its location: "N. ● text" and the thread tag.
  function Q.entry(n, i) return ("%d. %s %s%s"):format(i, C.KINDS[n.kind].sign, Q.text(n), Q.tag(n)) end

  local qf_ns = api.nvim_create_namespace "agent_notes_qf"
  local items -- the list's items while its window is drawn

  api.nvim_set_decoration_provider(qf_ns, {
    on_win = function(_, win, buf)
      items = nil
      if vim.bo[buf].buftype ~= "quickfix" or not S.qf_id then return false end
      local info = vim.fn.getwininfo(win)[1]
      if info.loclist == 1 or vim.fn.getqflist({ id = 0 }).id ~= S.qf_id then return false end
      items = vim.fn.getqflist({ id = S.qf_id, items = 1 }).items
    end,
    on_line = function(_, _, buf, row)
      local item = items and items[row + 1]
      local n = item and C.by_id(item.user_data)
      if not n then return end
      local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      local from = line:match "^[^|]*|[^|]*| ()"
      if not from then return end
      local tag = Q.tag(n)
      local stop = (tag ~= "" and line:sub(-#tag) == tag) and #line - #tag or #line
      local opts = { end_col = stop, hl_group = C.KINDS[n.kind].hl, ephemeral = true }
      api.nvim_buf_set_extmark(buf, qf_ns, row, from - 1, opts)
      if stop < #line then
        local hl = (n.unread or 0) > 0 and "AgentNoteUnread" or "Comment"
        api.nvim_buf_set_extmark(buf, qf_ns, row, stop, { end_col = #line, hl_group = hl, ephemeral = true })
      end
    end,
  })

  return Q
end
