-- Options for setup(): defaults, validation, and the highlight groups and keymaps
-- they apply. plugin/agent-notes.lua creates the <Plug> maps and :AgentNotes from
-- ACTIONS; setup() maps the configured keys to those <Plug> maps.
local M = {}

local api = vim.api

-- Every :AgentNotes action, in completion order: the module function it calls when
-- that is not its name, its description, its default key if it has one, and
-- whether it needs replies on.
M.ACTIONS = {
  { name = "next", key = "<Leader>an", desc = "Next agent note" },
  { name = "prev", key = "<Leader>ap", desc = "Previous agent note" },
  { name = "list", fn = "open", key = "<Leader>al", desc = "Agent notes list" },
  { name = "show", key = "<Leader>as", desc = "Toggle agent note" },
  { name = "enter", key = "<Leader>ae", desc = "Enter agent note" },
  { name = "follow", key = "<Leader>ag", desc = "Follow agent note link" },
  { name = "reply", key = "<Leader>ar", desc = "Reply to agent note", replies = true },
  { name = "autofloat", key = "<Leader>af", desc = "Toggle agent note float on step" },
  { name = "inline", key = "<Leader>ai", desc = "Toggle inline agent notes" },
  { name = "replies", desc = "Print replies to agent notes", replies = true },
  { name = "summary", desc = "Print agent notes summary" },
  { name = "clear", desc = "Clear agent notes" },
  { name = "reload", desc = "Reload agent-notes.nvim" },
}

--- The <Plug> map for an action: "list" is <Plug>(AgentNotesList).
function M.plug(name) return ("<Plug>(AgentNotes%s)"):format(name:sub(1, 1):upper() .. name:sub(2)) end

-- Highlight group of each `highlights` key, with its default link.
M.HIGHLIGHTS = {
  info = { "AgentNoteInfo", "DiagnosticInfo" },
  warn = { "AgentNoteWarn", "DiagnosticWarn" },
  issue = { "AgentNoteIssue", "DiagnosticError" },
  you = { "AgentNoteYou", "DiagnosticOk" },
  step = { "AgentNoteStep", "Comment" },
}

-- display: whether notes show as virtual lines, and whether stepping opens the float.
M.DISPLAY = {
  both = { inline = true, float = true },
  inline = { inline = true, float = false },
  float = { inline = false, float = true },
}

function M.defaults()
  local keymaps = {}
  for _, a in ipairs(M.ACTIONS) do
    if a.key then keymaps[a.name] = a.key end
  end
  return { socket = false, display = "both", replies = true, highlights = {}, keymaps = keymaps }
end

local function fail(msg, ...) error("AgentNotes.setup: " .. msg:format(...), 0) end

local function warn_unknown(tbl, known, prefix)
  for k in pairs(tbl) do
    if known[k] == nil then
      vim.notify(("AgentNotes.setup: unknown option %s%s"):format(prefix, tostring(k)), vim.log.levels.WARN)
    end
  end
end

local function expect(name, value, kind)
  if type(value) ~= kind then fail("%s must be a %s, got %s", name, kind, type(value)) end
end

--- Validates opts (nil means all defaults) and returns the effective config, a new
--- table. Raises on a bad value; warns about unknown keys and ignores them.
function M.resolve(opts)
  local cfg = M.defaults()
  if opts == nil then return cfg end
  expect("opts", opts, "table")
  warn_unknown(opts, cfg, "")
  for _, name in ipairs { "socket", "replies" } do
    if opts[name] ~= nil then
      expect(name, opts[name], "boolean")
      cfg[name] = opts[name]
    end
  end
  if opts.display ~= nil then
    if not M.DISPLAY[opts.display] then
      fail('display must be "both", "inline" or "float", got %s', vim.inspect(opts.display))
    end
    cfg.display = opts.display
  end
  if opts.highlights ~= nil then
    expect("highlights", opts.highlights, "table")
    warn_unknown(opts.highlights, M.HIGHLIGHTS, "highlights.")
    for key, spec in pairs(opts.highlights) do
      if M.HIGHLIGHTS[key] then
        expect("highlights." .. key, spec, "table")
        cfg.highlights[key] = spec
      end
    end
  end
  if opts.keymaps == false then
    cfg.keymaps = false
  elseif opts.keymaps ~= nil then
    expect("keymaps", opts.keymaps, "table")
    warn_unknown(opts.keymaps, cfg.keymaps, "keymaps.")
    for name in pairs(cfg.keymaps) do
      local lhs = opts.keymaps[name]
      if lhs ~= nil then
        if lhs ~= false and (type(lhs) ~= "string" or lhs == "") then
          fail("keymaps.%s must be a key string or false, got %s", name, vim.inspect(lhs))
        end
        cfg.keymaps[name] = lhs
      end
    end
  end
  return cfg
end

-- Sets the default links, without replacing a group the user or colourscheme
-- already defined, then cfg's overrides, which win.
local function set_highlights(cfg)
  for key, hl in pairs(M.HIGHLIGHTS) do
    api.nvim_set_hl(0, hl[1], { link = hl[2], default = true })
    if cfg.highlights[key] then api.nvim_set_hl(0, hl[1], cfg.highlights[key]) end
  end
end

--- Raises on a highlights spec that nvim_set_hl rejects, trying each on a
--- scratch group so no AgentNote group changes.
function M.check_highlights(cfg)
  for key, spec in pairs(cfg.highlights) do
    local ok, err = pcall(api.nvim_set_hl, 0, "AgentNoteCheck", spec)
    api.nvim_set_hl(0, "AgentNoteCheck", {})
    if not ok then fail("highlights.%s: %s", key, err) end
  end
end

--- Applies cfg's highlights now and after every :colorscheme. A group that prev
--- overrode and cfg does not goes back to its default link.
function M.apply_highlights(cfg, prev)
  for key, hl in pairs(M.HIGHLIGHTS) do
    if prev and prev.highlights[key] and not cfg.highlights[key] then api.nvim_set_hl(0, hl[1], { link = hl[2] }) end
  end
  set_highlights(cfg)
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("agent_notes_highlights", { clear = true }),
    callback = function() set_highlights(cfg) end,
  })
end

local function tokens(lhs)
  local out, i = {}, 1
  while i <= #lhs do
    local t = lhs:match("^<[^<>]+>", i) or lhs:sub(i, i)
    out[#out + 1] = t
    i = i + #t
  end
  return out
end

--- The prefix shared by every lhs, such as "<Leader>a", when it is at least two
--- keys long and shorter than each lhs; nil otherwise.
function M.group_prefix(lhss)
  local common
  for _, lhs in ipairs(lhss) do
    local t = tokens(lhs)
    if not common then
      common = vim.list_slice(t, 1, #t - 1)
    else
      local n = 0
      while n < #common and n < #t - 1 and common[n + 1] == t[n + 1] do
        n = n + 1
      end
      common = vim.list_slice(common, 1, n)
    end
  end
  if common and #common >= 2 then return table.concat(common) end
end

--- Maps cfg's keys to the <Plug> maps, after removing the keys an earlier call
--- mapped that still point at them. S.keymaps keeps the mapped keys across reloads.
function M.apply_keymaps(cfg, S)
  -- Global maps only: a buffer-local map on the same key must not hide ours.
  local global = {}
  for _, m in ipairs(api.nvim_get_keymap "n") do
    global[m.lhsraw or m.lhs] = m.rhs
  end
  for _, m in ipairs(S.keymaps or {}) do
    if global[m.raw] == m.rhs then api.nvim_del_keymap("n", m.lhs) end
  end
  S.keymaps = {}
  local lhss = {}
  for _, a in ipairs(M.ACTIONS) do
    local lhs = cfg.keymaps and cfg.keymaps[a.name]
    if lhs and (cfg.replies or not a.replies) then
      local rhs = M.plug(a.name)
      vim.keymap.set("n", lhs, rhs, { remap = true, desc = a.desc })
      local d = vim.fn.maparg(lhs, "n", false, true)
      S.keymaps[#S.keymaps + 1] = { lhs = d.lhs, raw = d.lhsraw or d.lhs, rhs = rhs }
      lhss[#lhss + 1] = lhs
    end
  end
  local prefix = M.group_prefix(lhss)
  -- Scheduled, so a lazy-loaded which-key is set up by then.
  if prefix then
    vim.schedule(function()
      pcall(function() require("which-key").add { { prefix, group = "Agent notes" } } end)
    end)
  end
end

--- The key mapped to action's <Plug> map in Normal mode, such as "<Space>ae", or nil.
function M.key_for(name)
  local plug = M.plug(name)
  for _, m in ipairs(api.nvim_get_keymap "n") do
    if m.rhs == plug then return vim.fn.keytrans(m.lhsraw or m.lhs) end
  end
end

return M
