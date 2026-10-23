-- Agent notes: non-destructive code annotations for walkthroughs and review.
--
-- plugin/agent-notes.lua loads this at startup; `:AgentNotes reload` re-requires it
-- and keeps existing notes. Notes show as a sign plus wrapped virtual lines under their first line, coloured by kind,
-- track their lines through edits with extmarks, and never modify the file.
-- API: AgentNotes.add{file=, line=, end_line=, kind=, text=, summary=, order=, channel=, viewed=}, open(),
-- next(), prev(), jump(i), lastreply(), show(), enter(), follow(), list(), summary(), viewed(),
-- clear([file | {file=, channel=}]), channel([id]), respond(id, text), reply(), replies([channel]),
-- autofloat([on]), inline([on]), setup(opts), config().
-- Links in text: [[path:line]] or [[path:line|label]]. Helpers live in agent-notes/*.lua.
if vim.fn.has "nvim-0.10" == 0 then error("AgentNotes needs nvim 0.10+", 0) end

local M = _G.AgentNotes or {}
_G.AgentNotes = M
M._state = M._state or { notes = {}, seq = 0 }
local S = M._state
local config = require "agent-notes.config"

-- The effective options. Until setup() runs they are the defaults; the display
-- toggles start from them and change only for the session.
if not S.config then
  S.config = config.resolve()
  S.inline, S.autofloat = true, true
end
config.apply_highlights(S.config)

local api = vim.api
local ns = api.nvim_create_namespace "agent_notes"
local track = api.nvim_create_namespace "agent_notes_track"
local TITLE = "Agent notes"
local BAR = "▍ "
-- Kind is shown by colour only, through diagnostic colours: usually blue, amber and red.
-- agent-notes/config.lua defines the highlight groups.
local KINDS = {
  info = { sign = "●", hl = "AgentNoteInfo" },
  warn = { sign = "▲", hl = "AgentNoteWarn" },
  issue = { sign = "■", hl = "AgentNoteIssue" },
}

local function abspath(path)
  local abs = vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(path), ":p"))
  return vim.uv.fs_realpath(abs) or abs
end
local function rel(path) return vim.fn.fnamemodify(path, ":~:.") end
local function span(l, e) return l == e and tostring(l) or ("%d-%d"):format(l, e) end

local function buf_of(n)
  if not api.nvim_buf_is_valid(n.buf) then n.buf = vim.fn.bufadd(n.path) end
  return n.buf
end

-- Current 1-based range, read from the tracking extmark when the buffer is loaded.
-- The mark ends at column 0 of the line after the range (exclusive), so deleting
-- the last line shrinks the range instead of pulling in the next line.
local function range(n)
  local buf = buf_of(n)
  if n.mark and api.nvim_buf_is_loaded(buf) then
    local m = api.nvim_buf_get_extmark_by_id(buf, track, n.mark, { details = true })
    if m[1] then
      local d = m[3]
      n.line = m[1] + 1
      n.end_line = math.max(n.line, d.end_row + (d.end_col > 0 and 1 or 0))
    end
  end
  return n.line, n.end_line
end

local function anchor(n)
  local buf = buf_of(n)
  if not api.nvim_buf_is_loaded(buf) then return end
  local last = api.nvim_buf_line_count(buf)
  n.line = math.min(n.line, last)
  n.end_line = math.max(n.line, math.min(n.end_line, last))
  n.mark = api.nvim_buf_set_extmark(buf, track, n.line - 1, 0, {
    id = n.mark,
    end_row = n.end_line,
    end_col = 0,
    strict = false,
  })
end

local function ordered()
  local list = vim.list_slice(S.notes)
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.id < b.id
  end)
  return list
end

local function by_id(id)
  for _, n in ipairs(S.notes) do
    if n.id == id then return n end
  end
end

local function position(n)
  for i, o in ipairs(ordered()) do
    if o == n then return i end
  end
end

-- Shared with the helper modules; they read these fields when called.
local C = {
  S = S,
  ns = ns,
  KINDS = KINDS,
  abspath = abspath,
  rel = rel,
  range = range,
  ordered = ordered,
  position = position,
  by_id = by_id,
  config = config,
}
for _, name in ipairs { "text", "markdown", "float", "diff", "replies", "viewed", "qf" } do
  C[name] = require("agent-notes." .. name)(C)
end
C.close_float = C.float.close

-- Narrowest text area among the windows showing buf, after sign/number/fold columns.
local function text_width(buf)
  local width
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if api.nvim_win_get_config(win).relative == "" then
      local info = vim.fn.getwininfo(win)[1]
      width = math.min(width or math.huge, info.width - info.textoff)
    end
  end
  return width or vim.o.columns - 8 -- not shown yet; re-wrapped on BufWinEnter
end

local function indent_of(buf, line)
  local lead = (api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""):match "^%s*"
  return #lead:gsub("\t", string.rep(" ", vim.bo[buf].tabstop))
end

-- Draws buf's notes as a sign plus virtual lines: "▍ 3/10 text", with wrapped
-- lines hanging under the text rather than the step number, and pads the
-- revision side of any diff showing buf to match. With inline notes off, only the sign.
local function render(buf, steps)
  if not api.nvim_buf_is_loaded(buf) then return end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not steps then
    steps = {}
    for i, n in ipairs(ordered()) do
      steps[n] = i
    end
  end
  local avail, heights = text_width(buf), {}
  for _, n in ipairs(S.notes) do
    if buf_of(n) == buf then
      local l, hl = range(n), KINDS[n.kind].hl
      local pad = string.rep(" ", math.min(indent_of(buf, l), math.max(0, avail - 30)))
      local step = ("%d/%d "):format(steps[n], #S.notes)
      local hang = string.rep(" ", #step)
      local width = avail - #pad - vim.fn.strdisplaywidth(BAR) - #step
      local virt = {}
      for i, text in ipairs(S.inline and n.lines or {}) do
        for j, piece in ipairs(C.text.wrap(text, width)) do
          local label = (i == 1 and j == 1) and { step, "AgentNoteStep" } or { hang }
          virt[#virt + 1] = { { pad .. BAR, hl }, label, { piece, hl } }
        end
      end
      api.nvim_buf_set_extmark(buf, ns, l - 1, 0, {
        virt_lines = #virt > 0 and virt or nil,
        sign_text = KINDS[n.kind].sign,
        sign_hl_group = hl,
      })
      if #virt > 0 then heights[l] = (heights[l] or 0) + #virt end
    end
  end
  C.diff.fill(buf, heights)
end

local function note_bufs()
  local bufs = {}
  for _, n in ipairs(S.notes) do
    bufs[buf_of(n)] = true
  end
  return bufs
end

-- Re-wraps every note buffer soon. A second pass after the redraw catches a
-- statuscolumn (heirline) whose width only settles when it is next drawn.
-- Step numbers change when notes are added or removed, so every note buffer redraws.
local function render_all()
  local steps = {}
  for i, n in ipairs(ordered()) do
    steps[n] = i
  end
  for buf in pairs(note_bufs()) do
    render(buf, steps)
  end
  C.replies.refresh_chat() -- its title shows the step too
end

local render_pending = false
local function render_all_soon()
  if render_pending then return end
  render_pending = true
  vim.schedule(function()
    render_pending = false
    render_all()
    vim.defer_fn(render_all, 50)
  end)
end

-- Picks a normal file window: the current one, the previous one, or any in the tab.
local function file_window()
  local function ok(w)
    return api.nvim_win_get_config(w).relative == "" and vim.bo[api.nvim_win_get_buf(w)].buftype == ""
  end
  local cur = api.nvim_get_current_win()
  if ok(cur) then return cur end
  local prev = vim.fn.win_getid(vim.fn.winnr "#")
  if prev ~= 0 and ok(prev) then return prev end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if ok(w) then return w end
  end
  return cur
end

-- Shows path:line, inside an open gitsigns diff view when there is one, then calls
-- done (later, when the diff has to be rebuilt for another file).
function C.goto_location(path, line, done)
  -- A newer jump supersedes a slower one still rebuilding a diff.
  S.nav = (S.nav or 0) + 1
  local nav = S.nav
  local after = done or function() end
  done = function()
    if S.nav == nav then after() end
  end
  local f = C.float.close()
  if f and api.nvim_win_is_valid(f.src_win) then api.nvim_set_current_win(f.src_win) end
  -- A diff being rebuilt, or one paused on an untracked file, still counts as open.
  local view = C.diff.current()
  for _, key in ipairs { "diff_pending", "diff_resume" } do
    local held = S[key]
    -- A paused diff counts only while its window still shows the file it paused on.
    local valid = held and api.nvim_win_is_valid(held.work)
    if valid and held.buf and api.nvim_win_get_buf(held.work) ~= held.buf then valid = false end
    if not view and valid then view = held end
  end
  S.diff_resume = nil
  api.nvim_set_current_win(view and view.work or file_window())
  vim.cmd "normal! m'"
  if view then
    return C.diff.go(view, path, line, done, function() return S.nav == nav end)
  end
  if abspath(api.nvim_buf_get_name(0)) ~= path then vim.cmd.edit(vim.fn.fnameescape(path)) end
  api.nvim_win_set_cursor(0, { math.max(1, math.min(line, api.nvim_buf_line_count(0))), 0 })
  vim.cmd "normal! zvzz"
  done()
end

-- Shows a link's target; landing there counts as viewing the notes on that line.
function C.follow_link(link) C.goto_location(link.path, link.line, C.viewed.at_cursor) end

function C.pick(links)
  local function go(l)
    if l then C.follow_link(l) end
  end
  if #links == 0 then
    vim.notify("This note has no links", vim.log.levels.WARN)
  elseif #links == 1 then
    go(links[1])
  else
    vim.ui.select(links, {
      prompt = "Follow link",
      format_item = function(l) return ("%s  %s:%d"):format(l.label, rel(l.path), l.line) end,
    }, go)
  end
end

function C.notes_at_cursor()
  local buf, row, found = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1], {}
  for _, n in ipairs(ordered()) do
    if buf_of(n) == buf then
      local l, e = range(n)
      if row >= l and row <= e then found[#found + 1] = n end
    end
  end
  return found
end

local function qf_valid() return S.qf_id and vim.fn.getqflist({ id = S.qf_id }).id == S.qf_id end

local function qf_sync()
  if not qf_valid() then return end
  local items, idx = {}, 1
  for i, n in ipairs(ordered()) do
    local l, e = range(n)
    items[i] = { bufnr = buf_of(n), lnum = l, end_lnum = e, text = C.qf.text(n), user_data = n.id }
    if n.id == S.current then idx = i end
  end
  vim.fn.setqflist({}, "r", { id = S.qf_id, title = TITLE, items = items })
  vim.fn.setqflist({}, "a", { id = S.qf_id, idx = idx })
  S.qf_idx = idx
end
C.qf_sync = qf_sync

-- The note the user selected in the notes list (<CR>, :cc, :cnext) since the last
-- check, if any.
function C.qf_selected()
  if not qf_valid() then return end
  local idx = vim.fn.getqflist({ id = S.qf_id, idx = 0 }).idx
  if idx == S.qf_idx then return end
  S.qf_idx = idx
  local item = vim.fn.getqflist({ id = S.qf_id, items = 1 }).items[idx]
  return item and by_id(item.user_data)
end

-- quickfixtextfunc: "path|line| N. ● text" keeps the qf syntax highlighting for the
-- location; agent-notes/qf.lua colours the rest by kind.
function M._qftf(info)
  local out = {}
  local items = vim.fn.getqflist({ id = info.id, items = 1 }).items
  for i = info.start_idx, info.end_idx do
    local n = by_id(items[i].user_data)
    if n then
      local loc = ("%s|%s|"):format(rel(n.path), span(n.line, n.end_line))
      out[#out + 1] = loc .. " " .. C.qf.entry(n, i)
    else
      out[#out + 1] = items[i].text
    end
  end
  return out
end

local function validate(spec)
  if type(spec) ~= "table" then error("AgentNotes.add: expected a table", 0) end
  local kind = spec.kind or "info"
  if not KINDS[kind] then error(("AgentNotes.add: kind must be info, warn or issue, got %s"):format(kind), 0) end
  if type(spec.file) ~= "string" or spec.file == "" then error("AgentNotes.add: file is required", 0) end
  if type(spec.text) ~= "string" or vim.trim(spec.text) == "" then error("AgentNotes.add: text is required", 0) end
  local line, end_line = tonumber(spec.line), tonumber(spec.end_line or spec.line)
  if not line or not end_line or line < 1 or end_line < line then
    error(("AgentNotes.add: bad line range %s-%s"):format(tostring(spec.line), tostring(spec.end_line)), 0)
  end
  if spec.order ~= nil and not tonumber(spec.order) then error("AgentNotes.add: order must be a number", 0) end
  if spec.viewed ~= nil and type(spec.viewed) ~= "boolean" then error("AgentNotes.add: viewed must be a boolean", 0) end
  local summary = spec.summary
  if summary ~= nil and (type(summary) ~= "string" or summary:find "[\r\n]" or vim.trim(summary) == "") then
    error("AgentNotes.add: summary must be a non-empty one-line string", 0)
  end
  return kind, math.floor(line), math.floor(end_line)
end

-- A swap file left by a dead nvim with unsaved changes, if any. Loading over it
-- would hide the recovery prompt from the user.
local function recoverable_swap(path)
  local file = vim.fs.basename(path)
  for _, swapdir in ipairs(vim.opt.directory:get()) do
    local base = swapdir:sub(-2) == "//" and vim.fs.normalize(swapdir:sub(1, -3)) .. "/" .. (path:gsub("/", "%%"))
      or (swapdir == "." and vim.fs.dirname(path) or vim.fs.normalize(swapdir))
        .. "/"
        .. (file:sub(1, 1) == "." and "" or ".")
        .. file
    for c in ("ponmlkjihgfedcba"):gmatch "." do
      local name = base .. ".sw" .. c
      if vim.uv.fs_stat(name) then
        local info = vim.fn.swapinfo(name)
        local alive, err = info.pid and info.pid > 0 and vim.uv.kill(info.pid, 0)
        alive = alive == 0 or (err ~= nil and err:find "EPERM" ~= nil)
        if info.dirty == 1 and not alive then return name end
      end
    end
  end
end

-- Loads path into an unlisted hidden buffer without the swap ATTENTION prompt, which
-- would otherwise abort the load; a swap held by a running nvim is edited anyway, as
-- after choosing (E)dit. Any failure unloads the buffer so no empty or partial buffer
-- stays behind under the file's name.
local function load(path)
  local existed = vim.fn.bufexists(path) == 1
  if existed and api.nvim_buf_is_loaded(vim.fn.bufadd(path)) then return vim.fn.bufadd(path) end
  local swap = recoverable_swap(path)
  if swap then error(("AgentNotes.add: %s has a swap file to recover first: %s"):format(path, swap), 0) end
  local buf = vim.fn.bufadd(path)
  local shortmess = vim.o.shortmess
  vim.opt.shortmess:append "A"
  local ok, err = pcall(vim.fn.bufload, buf)
  vim.o.shortmess = shortmess
  if not ok or api.nvim_buf_line_count(buf) ~= math.max(1, #vim.fn.readfile(path)) then
    pcall(api.nvim_buf_delete, buf, { force = true, unload = existed })
    error(("AgentNotes.add: could not load %s: %s"):format(path, ok and "line count mismatch" or err), 0)
  end
  if not existed then vim.bo[buf].buflisted = false end
  -- gitsigns attaches on BufRead only when the buffer is shown; a hidden load
  -- would otherwise leave it without signs when the user opens it.
  if package.loaded.gitsigns then require("gitsigns").attach { bufnr = buf } end
  return buf
end

--- Adds one note and returns its id.
function M.add(spec)
  -- JSON null decodes to vim.NIL; treat it as absent.
  if type(spec) == "table" then
    for k, v in pairs(spec) do
      if v == vim.NIL then spec[k] = nil end
    end
  end
  local kind, line, end_line = validate(spec)
  local path = abspath(spec.file)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then error("AgentNotes.add: no such file: " .. path, 0) end
  local lines, spans, links = C.text.parse(spec.text)
  local open = vim.fn.bufexists(path) == 1 and vim.fn.bufadd(path)
  local count = open and api.nvim_buf_is_loaded(open) and api.nvim_buf_line_count(open)
    or math.max(1, #vim.fn.readfile(path))
  if end_line > count then error(("AgentNotes.add: %s has %d lines, got %d"):format(rel(path), count, end_line), 0) end
  -- With replies off the note is added without its channel, so it cannot be replied to.
  local channel = spec.channel and S.config.replies and C.replies.resolve(spec.channel) or nil
  local buf = load(path)
  local max_order = 0
  for _, n in ipairs(S.notes) do
    local l, e = range(n)
    local same = n.path == path and l == line and e == end_line and n.kind == kind and n.text == spec.text
    if same and n.channel == channel then
      n.viewed = n.viewed or spec.viewed
      n.summary = spec.summary or n.summary
      qf_sync()
      return n.id
    end
    max_order = math.max(max_order, n.order)
  end
  S.seq = S.seq + 1
  local n = {
    id = S.seq,
    path = path,
    buf = buf,
    line = line,
    end_line = end_line,
    kind = kind,
    text = spec.text,
    summary = spec.summary,
    lines = lines,
    spans = spans,
    links = links,
    order = tonumber(spec.order) or max_order + 1,
    channel = channel,
    -- Carried forward when the agent re-adds a note the user has seen; no view event.
    viewed = spec.viewed,
  }
  S.notes[#S.notes + 1] = n
  anchor(n)
  render_all()
  qf_sync()
  return n.id
end

--- Notes in reading order, as plain tables.
function M.list()
  return vim.tbl_map(function(n)
    local l, e = range(n)
    return {
      id = n.id,
      order = n.order,
      kind = n.kind,
      file = n.path,
      line = l,
      end_line = e,
      text = n.text,
      summary = n.summary,
      links = n.links,
      thread = n.thread or {},
      unread = n.unread or 0,
      viewed = n.viewed or false,
      first_viewed = n.first_viewed,
      last_viewed = n.last_viewed,
    }
  end, ordered())
end

--- Prints and returns one line per note in reading order:
--- "N. #id [kind] [viewed|unviewed] path:lines  first line", then the summary and links.
function M.summary()
  local out = {}
  for i, n in ipairs(ordered()) do
    local l, e = range(n)
    local links = vim.tbl_map(function(k) return ("%s -> %s:%d"):format(k.label, rel(k.path), k.line) end, n.links)
    local suffix = (n.summary and "  (summary: " .. n.summary .. ")" or "")
      .. (#links > 0 and "  (links: " .. table.concat(links, ", ") .. ")" or "")
    local seen = n.viewed and "viewed" or "unviewed"
    out[i] = ("%d. #%d [%s] [%s] %s:%s  %s%s"):format(i, n.id, n.kind, seen, n.path, span(l, e), n.lines[1], suffix)
  end
  local s = #out > 0 and table.concat(out, "\n") or "No agent notes"
  print(s)
  return s
end

-- Steps to n, opening its float when float is set.
local function show_note(n, float)
  S.current = n.id
  C.goto_location(n.path, (range(n)), function()
    C.viewed.mark { n }
    if float then C.float.open({ n }, false) end
    qf_sync()
  end)
end

--- Jumps to the i-th note in reading order and shows it.
function M.jump(i)
  local n = ordered()[i]
  if not n then return print "No agent notes" end
  show_note(n, S.autofloat)
end

--- Steps to the note with the latest agent reply and opens its float.
function M.lastreply()
  local latest
  for _, n in ipairs(S.notes) do
    if n.reply_seq and (not latest or n.reply_seq > latest.reply_seq) then latest = n end
  end
  if not latest then return print "No agent reply yet" end
  show_note(latest, true)
end

-- Sets a display toggle for this session; no argument toggles it.
local function toggle(key, on, label)
  if on == nil then on = not S[key] end
  S[key] = on and true or false
  vim.notify(("Agent notes: %s %s"):format(label, S[key] and "on" or "off"))
  return S[key]
end

--- Sets whether stepping opens the note float for this session; no argument
--- toggles. `display` in setup() sets where it starts.
function M.autofloat(on) return toggle("autofloat", on, "float on step") end

--- Sets whether notes show as virtual lines for this session; no argument toggles.
--- The sign stays either way. `display` in setup() sets where it starts.
function M.inline(on)
  local value = toggle("inline", on, "inline notes")
  render_all()
  return value
end

local function step(delta)
  local list = ordered()
  if #list == 0 then return print "No agent notes" end
  local pos
  for i, n in ipairs(list) do
    if n.id == S.current then pos = i end
  end
  if not pos then return M.jump(delta > 0 and 1 or #list) end
  M.jump((pos - 1 + delta) % #list + 1)
end

--- Next/previous note in reading order, wrapping at either end.
function M.next() step(1) end
function M.prev() step(-1) end

local function float_open() return S.float and api.nvim_win_is_valid(S.float.win) end

local function open_at_cursor(focus)
  local found = C.notes_at_cursor()
  if #found == 0 then return print "No agent note on this line" end
  C.float.open(found, focus)
end

--- Toggles the float for the notes on the cursor line.
function M.show()
  if float_open() then return C.float.close() end
  open_at_cursor(false)
end

--- Enters the note float, opening it for the cursor line first if needed.
function M.enter()
  if float_open() then return api.nvim_set_current_win(S.float.win) end
  open_at_cursor(true)
end

--- Follows a link from the focused float, the notes list, or the notes on the cursor line.
function M.follow()
  local win = api.nvim_get_current_win()
  if S.float and win == S.float.win then return C.float.follow_here() end
  local notes = C.notes_at_cursor()
  if vim.bo.buftype == "quickfix" and qf_valid() and vim.fn.getqflist({ id = 0 }).id == S.qf_id then
    local item = vim.fn.getqflist({ id = S.qf_id, items = 1 }).items[api.nvim_win_get_cursor(win)[1]]
    notes = { item and by_id(item.user_data) }
  end
  local links = {}
  for _, n in ipairs(notes) do
    vim.list_extend(links, n.links)
  end
  C.pick(links)
end

--- Opens the notes list: a dedicated, titled quickfix list made current, then :copen.
function M.open()
  if #S.notes == 0 then return print "No agent notes" end
  if not qf_valid() then
    vim.fn.setqflist({}, " ", { nr = "$", title = TITLE, items = {}, quickfixtextfunc = "v:lua.AgentNotes._qftf" })
    S.qf_id = vim.fn.getqflist({ nr = "$", id = 0 }).id
  end
  qf_sync()
  local delta = vim.fn.getqflist({ id = S.qf_id, nr = 0 }).nr - vim.fn.getqflist({ nr = 0 }).nr
  if delta ~= 0 then vim.cmd(("silent %d%s"):format(math.abs(delta), delta > 0 and "cnewer" or "colder")) end
  vim.cmd "botright copen"
end

--- Removes notes and returns how many: all of them, those in a file (string), or
--- those matching { file = ?, channel = ? }.
function M.clear(filter)
  if type(filter) == "string" then filter = { file = filter } end
  filter = filter or {}
  local path = filter.file and abspath(filter.file)
  local channel = filter.channel and C.replies.resolve(filter.channel, false)
  local keep, bufs, removed = {}, {}, 0
  for _, n in ipairs(S.notes) do
    if (path and n.path ~= path) or (channel and n.channel ~= channel) then
      keep[#keep + 1] = n
    else
      local buf = buf_of(n)
      if n.mark and api.nvim_buf_is_loaded(buf) then api.nvim_buf_del_extmark(buf, track, n.mark) end
      bufs[buf], removed = true, removed + 1
    end
  end
  S.notes = keep
  if not by_id(S.current) then S.current = nil end
  if S.chat and not vim.tbl_contains(S.notes, S.chat.note) then C.replies.close_chat() end
  C.float.close()
  C.replies.close_toast()
  for buf in pairs(bufs) do
    render(buf)
  end
  render_all()
  qf_sync()
  return removed
end

M.viewed = C.viewed.report
M.channel = C.replies.channel
M.reply = C.replies.reply
M.replies = C.replies.replies

--- Adds the agent's response to note id's thread and tells the user.
function M.respond(id, text)
  local n = by_id(tonumber(id))
  if not n then error(("AgentNotes.respond: no note #%s"):format(tostring(id)), 0) end
  if type(text) ~= "string" or vim.trim(text) == "" then error("AgentNotes.respond: text is required", 0) end
  C.replies.record(n, "response", text)
  vim.notify(("Agent replied to note %d: %s"):format(position(n), text:match "^[^\n]*"))
  local f = S.float
  if float_open() and vim.tbl_contains(f.notes, n) and api.nvim_win_is_valid(f.src_win) then
    local focused = api.nvim_get_current_win() == f.win
    api.nvim_set_current_win(f.src_win)
    C.float.open(f.notes, focused)
  end
  -- An open float or chat has shown the reply already.
  if (n.unread or 0) > 0 then C.replies.toast(n) end
  qf_sync()
end

local group = api.nvim_create_augroup("agent_notes", { clear = true })
api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
  group = group,
  callback = function(ev)
    if note_bufs()[ev.buf] then render(ev.buf) end
  end,
})
-- Re-wrap when a window showing a note buffer changes width or a new one shows it,
-- and re-pad diff revision sides when a diff opens, closes or changes.
api.nvim_create_autocmd({ "VimResized", "WinResized", "WinClosed", "BufWinEnter", "DiffUpdated" }, {
  group = group,
  callback = render_all_soon,
})
-- Level from the window that scrolled: the current one, or the one under a
-- mouse wheel.
api.nvim_create_autocmd("WinScrolled", {
  group = group,
  callback = function(ev)
    local cur = api.nvim_get_current_win()
    local win = vim.v.event[tostring(cur)] and cur or tonumber(ev.match)
    if win and api.nvim_win_is_valid(win) then C.diff.level(win) end
  end,
})
api.nvim_create_autocmd("OptionSet", {
  group = group,
  pattern = { "number", "relativenumber", "numberwidth", "signcolumn", "foldcolumn", "tabstop", "diff" },
  callback = render_all_soon,
})
-- A reloaded or re-read buffer loses its extmarks; re-anchor from the last known lines.
api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function(ev)
    local hit = false
    for _, n in ipairs(S.notes) do
      if buf_of(n) == ev.buf then
        hit = true
        anchor(n)
      end
    end
    if hit then render(ev.buf) end
  end,
})

--- Applies options; see the README. Calling it again replaces the earlier options,
--- and `:AgentNotes reload` calls it again with the same ones. Raises on a bad value
--- and then changes nothing.
function M.setup(opts)
  local cfg = config.resolve(opts)
  config.check(cfg)
  config.apply_highlights(cfg, S.config)
  S.opts, S.config = opts or {}, cfg
  local display = config.DISPLAY[cfg.display]
  S.inline, S.autofloat = display.inline, display.float
  -- A chat already open stays open with replies off, so a draft in it is not lost.
  config.apply_keymaps(cfg, S)
  require("agent-notes.socket").enable(cfg.socket)
  render_all()
  qf_sync() -- list_text may have changed
end

--- A copy of the effective options: the defaults merged with those given to setup().
function M.config() return vim.deepcopy(S.config) end

-- Re-render after a reload so notes pick up any rendering changes.
C.float.close()
C.replies.close_chat()
C.replies.close_toast()
render_all()
return M
