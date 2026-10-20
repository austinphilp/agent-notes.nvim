-- Keeps a gitsigns diff view (<Leader>gd / <Leader>gD run gitsigns.diffthis) on the
-- note being shown: the working side moves to the note, the revision side follows
-- through diff scrollbind, and a note in another file re-opens the diff for that
-- file against the same revision.
return function(C)
  local api = vim.api
  local D = {}

  -- gitsigns names revision buffers gitsigns://<gitdir>//<rev>:<relpath>; the index is ":0".
  local function revision_of(name)
    local rest = name:match "^gitsigns://.-//(.*)$"
    if not rest then return end
    return rest:match "^(:%d+):" or rest:match "^([^:]+):"
  end

  --- The gitsigns diff in the current tab, if any: { work = win, revs = { win... }, rev = string }.
  function D.current()
    local view = { revs = {} }
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      local buf = api.nvim_win_get_buf(w)
      if vim.wo[w].diff and api.nvim_win_get_config(w).relative == "" then
        local rev = revision_of(api.nvim_buf_get_name(buf))
        if rev then
          view.revs[#view.revs + 1], view.rev = w, rev
        elseif vim.bo[buf].buftype == "" then
          view.work = view.work or w
        end
      end
    end
    -- ":2"/":3" are the sides of a conflict view, which this does not rebuild.
    if view.work and #view.revs > 0 and view.rev ~= ":2" and view.rev ~= ":3" then return view end
  end

  local fill = api.nvim_create_namespace "agent_notes_fill"

  -- Diff row of each of win's lines 1..last: the line plus the diff filler above
  -- it. Virtual lines are not counted, so rows match across the windows of a diff.
  local function rows(win, last)
    return api.nvim_win_call(win, function()
      local out, r = {}, 0
      for l = 1, last do
        r = r + 1 + vim.fn.diff_filler(l)
        out[l] = r
      end
      return out
    end)
  end

  -- The revision line whose row is the last one at or above row, or 0.
  local function counterpart(rev_rows, row)
    local lo, hi = 0, #rev_rows
    while lo < hi do
      local mid = math.ceil((lo + hi) / 2)
      if rev_rows[mid] <= row then lo = mid else hi = mid - 1 end
    end
    return lo
  end

  --- Pads the revision side of each diff showing buf with blank virtual lines, so
  --- rows below a note stay level with their counterpart. heights maps a working
  --- line to the virtual lines drawn under it. A note on an added line pads the
  --- last revision line above it, which keeps the rows after the hunk level.
  function D.fill(buf, heights)
    local S = C.S
    S.fills = S.fills or {}
    for rev in pairs(S.fills[buf] or {}) do
      if api.nvim_buf_is_valid(rev) then api.nvim_buf_clear_namespace(rev, fill, 0, -1) end
    end
    S.fills[buf] = nil
    if not next(heights) then return end
    local last = math.max(unpack(vim.tbl_keys(heights)))
    local filled = {}
    for _, work in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.wo[work].diff and api.nvim_win_get_config(work).relative == "" then
        local work_rows
        for _, w in ipairs(api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(work))) do
          local rev = api.nvim_win_get_buf(w)
          if vim.wo[w].diff and not filled[rev] and revision_of(api.nvim_buf_get_name(rev)) then
            filled[rev] = true
            work_rows = work_rows or rows(work, last)
            local rev_rows, pad = rows(w, api.nvim_buf_line_count(rev)), {}
            for line, h in pairs(heights) do
              local m = counterpart(rev_rows, work_rows[line])
              pad[m] = (pad[m] or 0) + h
            end
            for m, h in pairs(pad) do
              local blank = {}
              for i = 1, h do
                blank[i] = { { "" } }
              end
              -- Above the first line when the note sits on lines added at the top.
              local opts = { virt_lines = blank, virt_lines_above = m == 0 }
              api.nvim_buf_set_extmark(rev, fill, math.max(m - 1, 0), 0, opts)
            end
          end
        end
      end
    end
    S.fills[buf] = next(filled) and filled or nil
    -- Scrollbind skips the new blanks until the next scroll; level the sides now
    -- from the current window when it is part of this diff.
    if not S.fills[buf] then return end
    vim.schedule(function()
      local cur = api.nvim_get_current_win()
      local shown = api.nvim_win_get_buf(cur)
      if vim.wo[cur].diff and (shown == buf or (S.fills[buf] or {})[shown]) then return D.level(cur) end
      for _, w in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.wo[w].diff and api.nvim_win_get_config(w).relative == "" then return D.level(w) end
      end
    end)
  end

  -- Screen rows above line l's text in win: earlier lines, folds and all filler.
  local function above(win, l) return api.nvim_win_text_height(win, { end_row = l - 1, end_vcol = 0 }).all end
  local function fill_above(win, l)
    return api.nvim_win_text_height(win, { start_row = l - 1, end_row = l - 1, end_vcol = 0 }).all
  end

  --- Scrolls the other side of win's padded diff to the screen row win shows at
  --- its top. Diff scrollbind ignores virtual lines, so a side scrolled partway
  --- through a note or its blanks would leave the other side off by that much.
  --- Rows are screen rows, which assumes diff mode's 'nowrap'.
  function D.level(win)
    local buf, group = api.nvim_win_get_buf(win), nil
    for work, revs in pairs(C.S.fills or {}) do
      if work == buf or revs[buf] then group = vim.tbl_extend("force", { [work] = true }, revs) end
    end
    if not group or not vim.wo[win].diff then return end
    local view = api.nvim_win_call(win, vim.fn.winsaveview)
    local row = above(win, view.topline) - view.topfill
    for _, w in ipairs(api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(win))) do
      if w ~= win and vim.wo[w].diff and group[api.nvim_win_get_buf(w)] then
        -- The first line whose text starts at or below row, then the filler above
        -- it that fits; a row inside a line's text or fold shows that line instead.
        local lo, hi = 1, api.nvim_buf_line_count(api.nvim_win_get_buf(w))
        while lo < hi do
          local mid = math.floor((lo + hi) / 2)
          if above(w, mid) >= row then hi = mid else lo = mid + 1 end
        end
        local top, topfill = lo, math.max(above(w, lo) - row, 0)
        if topfill > fill_above(w, top) then
          top, topfill = math.max(top - 1, 1), 0
        end
        api.nvim_win_call(w, function()
          local closed = vim.fn.foldclosed(top)
          local want = { topline = closed > 0 and closed or top, topfill = topfill }
          local cur = vim.fn.winsaveview()
          if cur.topline == want.topline and cur.topfill == want.topfill then return end
          vim.fn.winrestview(want)
          -- A cursor left outside the view would scroll it back at the next redraw.
          want.lnum = math.min(math.max(cur.lnum, want.topline), vim.fn.line "w$")
          if want.lnum ~= cur.lnum then vim.fn.winrestview(want) end
        end)
      end
    end
  end

  local function place(win, line)
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { math.max(1, math.min(line, api.nvim_buf_line_count(0))), 0 })
    -- No :syncbind: it ignores virtual lines and misaligns the sides; diff
    -- scrollbind aligns the revision side at the next redraw.
    vim.cmd "normal! zvzz"
  end

  -- diffthis asserts that the buffer's first gitsigns update has run, which the
  -- public API does not expose; fall back to the attach marker if internals move.
  local function ready(buf)
    if not vim.b[buf].gitsigns_status_dict then return false end
    local ok, cache = pcall(require, "gitsigns.cache")
    local entry = ok and type(cache.cache) == "table" and cache.cache[buf]
    return not entry or entry.compare_text ~= nil
  end

  -- Calls cb(true) once gitsigns is ready to diff buf, or cb(false) after ~2s.
  local function when_attached(buf, cb, tries)
    tries = tries or 0
    if tries == 0 and not vim.b[buf].gitsigns_status_dict then require("gitsigns").attach { bufnr = buf } end
    if ready(buf) then return cb(true) end
    if tries >= 40 or not api.nvim_buf_is_valid(buf) then return cb(false) end
    vim.defer_fn(function() when_attached(buf, cb, tries + 1) end, 50)
  end

  -- Tidies up after a superseded rebuild whose diffthis finished late: keeps one
  -- revision window for the working buffer's file and closes the rest.
  local function prune(work)
    if not api.nvim_win_is_valid(work) then return end
    local path = C.abspath(api.nvim_buf_get_name(api.nvim_win_get_buf(work)))
    local keep = true
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      local relpath = api.nvim_buf_get_name(api.nvim_win_get_buf(w)):match "^gitsigns://.-//:?[^:]*:(.*)$"
      if relpath then
        if keep and path:sub(-#relpath - 1) == "/" .. relpath then
          keep = false
        else
          api.nvim_win_close(w, true)
        end
      end
    end
  end

  --- Shows path:line on the working side of view, then calls done (maybe later).
  --- current() tells whether this jump is still the latest one. While a diff is
  --- rebuilt, S.diff_pending holds the job: a step to the same file retargets it
  --- instead of starting another, and goto_location treats it as the open diff.
  function D.go(view, path, line, done, current)
    done = done or function() end
    current = current or function() return true end
    local job = C.S.diff_pending
    if job and view == job and job.path == path then
      job.line, job.done, job.current = line, done, current
      return place(view.work, line)
    end
    local same = C.abspath(api.nvim_buf_get_name(api.nvim_win_get_buf(view.work))) == path
    if same and #view.revs > 0 then
      place(view.work, line)
      return done()
    end
    -- Close every gitsigns revision window in the tab, including the :2/:3 sides
    -- of a conflict view that view.revs does not track.
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_buf_get_name(api.nvim_win_get_buf(w)):match "^gitsigns://" then api.nvim_win_close(w, true) end
    end
    api.nvim_set_current_win(view.work)
    vim.cmd "diffoff"
    if not same then vim.cmd.edit(vim.fn.fnameescape(path)) end
    place(view.work, line)
    job = { work = view.work, revs = {}, rev = view.rev, path = path, line = line, done = done, current = current }
    C.S.diff_pending, C.S.diff_resume = job, nil
    local function finish(msg)
      if C.S.diff_pending == job then C.S.diff_pending = nil end
      if not job.current() then return prune(job.work) end
      if msg then vim.notify("AgentNotes: " .. msg, vim.log.levels.WARN) end
      -- No diff for this file (untracked, not in git): remember the revision so
      -- the next step to a tracked file restores the diff.
      if not D.current() and api.nvim_win_is_valid(job.work) then
        local buf = api.nvim_win_get_buf(job.work)
        C.S.diff_resume = { work = job.work, buf = buf, revs = {}, rev = job.rev }
      end
      if api.nvim_win_is_valid(job.work) then place(job.work, job.line) end
      job.done()
    end
    local buf = api.nvim_get_current_buf()
    -- Outside any git repo there is nothing to wait for.
    if not vim.fs.root(path, ".git") then return finish() end
    when_attached(buf, function(attached)
      if not job.current() then return finish() end
      if not attached then return finish("no git diff for " .. C.rel(path)) end
      api.nvim_set_current_win(job.work)
      require("gitsigns").diffthis(job.rev ~= ":0" and job.rev or nil, nil, function(err)
        vim.schedule(function() finish(err and "gitsigns diffthis: " .. err) end)
      end)
    end)
  end

  return D
end
