-- Note text: [[path:line|label]] links and word wrapping.
return function(C)
  local T = {}

  -- Replaces [[path:line]] and [[path:line|label]] with ‹label›, recording link spans per line.
  function T.parse(text)
    local lines, spans, links = {}, {}, {}
    for raw in (text .. "\n"):gmatch "(.-)\n" do
      local out, pos = "", 1
      for s, inner, e in raw:gmatch "()%[%[(.-)%]%]()" do
        local target, label = inner:match "^([^|]*)|(.*)$"
        target = target or inner
        local path, line = target:match "^(.-):(%d+)$"
        path, line = path or target, tonumber(line) or 1
        local abs = C.abspath(path)
        local stat = path ~= "" and vim.uv.fs_stat(abs)
        if not stat or stat.type ~= "file" then
          error(("AgentNotes: link target not found: [[%s]]"):format(inner), 0)
        end
        local count = #vim.fn.readfile(abs)
        if line < 1 or line > count then
          error(("AgentNotes: link target %s has %d lines: [[%s]]"):format(C.rel(abs), count, inner), 0)
        end
        label = (label and label ~= "") and label or ("%s:%d"):format(C.rel(abs), line)
        links[#links + 1] = { path = abs, line = line, label = label }
        out = out .. raw:sub(pos, s - 1)
        spans[#spans + 1] = { row = #lines + 1, s = #out, e = #out + #label + 6, link = #links }
        out, pos = out .. "‹" .. label .. "›", e
      end
      lines[#lines + 1] = out .. raw:sub(pos)
    end
    return lines, spans, links
  end

  local width_of = vim.fn.strdisplaywidth

  -- Splits a word wider than width into pieces that fit.
  local function hard_break(word, width, out)
    local piece = ""
    for _, ch in ipairs(vim.fn.split(word, "\\zs")) do
      if piece ~= "" and width_of(piece .. ch) > width then
        out[#out + 1] = piece
        piece = ""
      end
      piece = piece .. ch
    end
    return piece
  end

  --- Word-wraps one line to width display cells; long words are broken.
  function T.wrap(s, width)
    width = math.max(1, width)
    if width_of(s) <= width then return { s } end
    local out, cur = {}, ""
    for gap, word in s:gmatch "(%s*)(%S+)" do
      local joined = cur == "" and word or cur .. gap .. word
      if width_of(joined) <= width then
        cur = joined
      else
        if cur ~= "" then out[#out + 1] = cur end
        cur = width_of(word) > width and hard_break(word, width, out) or word
      end
    end
    if cur ~= "" then out[#out + 1] = cur end
    return out
  end

  return T
end
