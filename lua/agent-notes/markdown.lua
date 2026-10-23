-- Basic markdown for the float and chat: drops the markers, returns highlight marks
-- for what they marked, and moves [[link]] spans to the shown text's columns.
-- Links are whole tokens: markup never starts or ends inside a ‹label›.
return function()
  local M = {}

  -- Highlight of a matched pair by delimiter character and how many it used.
  local HL = {
    ["*"] = { "AgentNoteItalic", "AgentNoteBold" },
    _ = { "AgentNoteItalic", "AgentNoteBold" },
    ["~"] = { nil, "AgentNoteStrike" },
  }

  local function blank(c) return c == "" or c:match "%s" ~= nil end
  local function word(c) return c:match "[%w\128-\255]" ~= nil end

  -- Splits src from byte from into text, links, code spans and delimiter runs.
  -- links maps a link's first byte in src to its span.
  local function tokenize(src, from, links)
    local tokens, i = {}, from
    local function text(a, b)
      local last = tokens[#tokens]
      if last and not last.ch and not last.code and last.b == a - 1 then
        last.b = b
      else
        tokens[#tokens + 1] = { a = a, b = b }
      end
    end
    -- The start of the backtick run of exactly n that closes a code span, skipping links.
    local function closing(j, n)
      while j <= #src do
        if links[j] then
          j = j + links[j].e - links[j].s
        elseif src:sub(j, j) == "`" then
          local m = #src:match("^`+", j)
          if m == n then return j end
          j = j + m
        else
          j = j + 1
        end
      end
    end
    while i <= #src do
      local c, l = src:sub(i, i), links[i]
      if l then
        text(i, i + l.e - l.s - 1)
        i = i + l.e - l.s
      elseif c == "`" then
        local n = #src:match("^`+", i)
        local j = closing(i + n, n)
        if j then
          local a, b = i + n, j - 1
          -- One space each side pads a span that starts or ends with a backtick.
          if src:sub(a, a) == " " and src:sub(b, b) == " " and src:sub(a, b):find "%S" then
            a, b = a + 1, b - 1
          end
          tokens[#tokens + 1] = { a = a, b = b, code = true }
          i = j + n
        else
          text(i, i + n - 1)
          i = i + n
        end
      elseif HL[c] then
        local n = #src:match("^%" .. c .. "+", i)
        local before, after = src:sub(i - 1, i - 1), src:sub(i + n, i + n)
        -- A run opens when text follows it and closes when text precedes it; _ never
        -- does inside a word, so snake_case stays as written. ~ marks only as ~~.
        local ok = c ~= "~" or n == 2
        local open = ok and not blank(after) and not (c == "_" and word(before))
        local close = ok and not blank(before) and not (c == "_" and word(after))
        tokens[#tokens + 1] = { a = i, b = i + n - 1, ch = c, n = n, open = open, close = close, lead = 0, trail = 0 }
        i = i + n
      else
        text(i, i)
        i = i + 1
      end
    end
    return tokens
  end

  -- Pairs delimiter runs as CommonMark does, simplified: each closer takes the
  -- nearest open run of its character, and the runs opened after that one stay as
  -- written. Returns the pairs, inner first.
  local function match(tokens)
    local stack, open, out = {}, {}, {}
    for _, t in ipairs(tokens) do
      if t.ch then
        while t.close and t.n > 0 and (open[t.ch] or 0) > 0 do
          local k = #stack
          while stack[k].ch ~= t.ch do
            k = k - 1
          end
          local o = stack[k]
          local use = math.min(2, o.n, t.n)
          o.n, o.trail, t.n, t.lead = o.n - use, o.trail + use, t.n - use, t.lead + use
          out[#out + 1] = { o = o, t = t, hl = HL[t.ch][use] }
          for m = #stack, o.n > 0 and k + 1 or k, -1 do
            open[stack[m].ch] = open[stack[m].ch] - 1
            stack[m] = nil
          end
        end
        if t.open and t.n > 0 then
          stack[#stack + 1] = t
          open[t.ch] = (open[t.ch] or 0) + 1
        end
      end
    end
    return out
  end

  -- Inline markup on src from byte from, after prefix. Returns the text, its marks
  -- and its moved spans.
  local function inline(src, from, prefix, links)
    local tokens = tokenize(src, from, links)
    local matched = match(tokens)
    local parts, len, marks, spans = { prefix }, #prefix, {}, {}
    -- Appends src[a..b] as is, moving any links inside it.
    local function raw(a, b)
      for k = a, b do
        local l = links[k]
        if l then spans[#spans + 1] = { s = len + k - a, e = len + k - a + l.e - l.s, link = l.link } end
      end
      parts[#parts + 1] = src:sub(a, b)
      len = len + math.max(0, b - a + 1)
    end
    for _, t in ipairs(tokens) do
      -- A run shows only the markers no pair used, between those it closed and opened.
      t.start = len
      if t.ch then
        parts[#parts + 1] = t.ch:rep(t.n)
        len = len + t.n
      elseif t.code then
        raw(t.a, t.b)
        marks[#marks + 1] = { s = t.start, e = len, hl = "AgentNoteCode" }
      else
        raw(t.a, t.b)
      end
      t.stop = len
    end
    for _, p in ipairs(matched) do
      if p.hl then marks[#marks + 1] = { s = p.o.stop, e = p.t.start, hl = p.hl } end
    end
    return table.concat(parts), marks, spans
  end

  --- Renders note lines with their link spans ({row, s, e, link}, byte columns,
  --- rows from 1). Returns the shown lines, highlight marks {row, s, e, hl} and
  --- the spans moved to the shown text. Code blocks and spans keep their text.
  function M.render(lines, spans)
    local out, marks, moved = {}, {}, {}
    local by_row = {}
    for _, s in ipairs(spans or {}) do
      by_row[s.row] = by_row[s.row] or {}
      by_row[s.row][s.s + 1] = s
    end
    local fence
    -- Adds a shown line with its inline marks and spans, and hl over all of it.
    local function add(text, shown, kept, hl)
      out[#out + 1] = text
      if hl then marks[#marks + 1] = { row = #out, s = 0, e = #text, hl = hl } end
      for _, m in ipairs(shown) do
        marks[#marks + 1] = { row = #out, s = m.s, e = m.e, hl = m.hl }
      end
      for _, s in ipairs(kept) do
        moved[#moved + 1] = { row = #out, s = s.s, e = s.e, link = s.link }
      end
    end
    for row, line in ipairs(lines) do
      local links = by_row[row] or {}
      local open = line:match "^%s*(```+)[^`]*$" or line:match "^%s*(~~~+)"
      if fence then
        local close = line:match "^%s*(```+)%s*$" or line:match "^%s*(~~~+)%s*$"
        if close and close:sub(1, 1) == fence:sub(1, 1) and #close >= #fence then
          fence = nil
        else
          local kept = {}
          for _, s in ipairs(spans or {}) do
            if s.row == row then kept[#kept + 1] = s end
          end
          add(line, {}, kept, "AgentNoteCode")
        end
      elseif open then
        fence = open
      else
        local prefix, from, hl = "", 1, nil
        local hashes, after = line:match "^(#+)%s+()"
        local indent, item = line:match "^(%s*)[-*+]%s+()"
        if hashes and #hashes <= 6 then
          from, hl = after, "AgentNoteHeading"
        elseif line:match "^%s*>" then
          prefix = line:match "^%s*"
          from = #prefix + 1
          while line:sub(from, from) == ">" do
            prefix, from = prefix .. "│ ", line:match("^>%s?()", from)
          end
          hl = "AgentNoteQuote"
        elseif indent then
          prefix, from = indent .. "• ", item
        end
        local text, shown, kept = inline(line, from, prefix, links)
        add(text, shown, kept, hl)
      end
    end
    return out, marks, moved
  end

  return M
end
