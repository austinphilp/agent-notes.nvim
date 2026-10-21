local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local DEFAULTS = {
  ["\\an"] = { "<Plug>(AgentNotesNext)", "Next agent note" },
  ["\\ap"] = { "<Plug>(AgentNotesPrev)", "Previous agent note" },
  ["\\al"] = { "<Plug>(AgentNotesList)", "Agent notes list" },
  ["\\as"] = { "<Plug>(AgentNotesShow)", "Toggle agent note" },
  ["\\ae"] = { "<Plug>(AgentNotesEnter)", "Enter agent note" },
  ["\\ag"] = { "<Plug>(AgentNotesFollow)", "Follow agent note link" },
  ["\\ar"] = { "<Plug>(AgentNotesReply)", "Reply to agent note" },
  ["\\af"] = { "<Plug>(AgentNotesAutofloat)", "Toggle agent note float on step" },
  ["\\ai"] = { "<Plug>(AgentNotesInline)", "Toggle inline agent notes" },
}

-- Normal-mode keys mapped to an agent-notes <Plug> map: { lhs = { rhs, desc } }.
local function mapped()
  local out = {}
  for _, m in ipairs(vim.api.nvim_get_keymap "n") do
    if m.rhs and m.rhs:find("<Plug>(AgentNotes", 1, true) then out[vim.fn.keytrans(m.lhsraw)] = { m.rhs, m.desc } end
  end
  return out
end

local function with(changes)
  local want = vim.deepcopy(DEFAULTS)
  for k, v in pairs(changes) do
    want[k] = v or nil
  end
  return want
end

-- Collects which-key groups, for a plugin that loads after the keymaps are set.
local groups = {}
package.loaded["which-key"] = { add = function(spec) groups[#groups + 1] = spec[1][1] end }
-- The group added since the last call, after the scheduled which-key calls run.
local function group()
  vim.wait(20)
  local g = groups[#groups]
  groups = {}
  return g
end

T.test("setup() maps the default keys", function()
  AgentNotes.setup()
  T.eq(DEFAULTS, mapped())
  T.eq("<Leader>a", group(), "which-key group")
end)

T.test("keys remap and false disables one, with no stale defaults", function()
  AgentNotes.setup { keymaps = { next = "]n", prev = "[n", reply = false } }
  T.eq(
    with {
      ["\\an"] = false,
      ["\\ap"] = false,
      ["\\ar"] = false,
      ["]n"] = { "<Plug>(AgentNotesNext)", "Next agent note" },
      ["[n"] = { "<Plug>(AgentNotesPrev)", "Previous agent note" },
    },
    mapped()
  )
  AgentNotes.setup()
  T.eq(DEFAULTS, mapped(), "setup again restores the defaults")
end)

T.test("keymaps = false maps no keys and adds no group", function()
  group()
  AgentNotes.setup { keymaps = false }
  T.eq({}, mapped())
  T.eq(nil, group(), "no which-key group")
  AgentNotes.setup()
end)

T.test("the which-key group follows the prefix in use", function()
  local keys = {}
  for name in pairs(AgentNotes.config().keymaps) do
    keys[name] = "<Space>n" .. name:sub(1, 1) .. name:sub(-1)
  end
  group()
  AgentNotes.setup { keymaps = keys }
  T.eq("<Space>n", group())
  AgentNotes.setup { keymaps = { next = "<leader>an", prev = "<Leader>ap" } }
  T.eq("<leader>a", group(), "<leader> and <Leader> are the same key")
  AgentNotes.setup { keymaps = false }
  AgentNotes.setup {
    keymaps = {
      next = "]n",
      prev = "]p",
      list = false,
      show = false,
      enter = false,
      follow = false,
      reply = false,
      autofloat = false,
      inline = false,
    },
  }
  T.eq(nil, group(), "a one-key prefix gets no group")
  AgentNotes.setup {
    keymaps = {
      next = "]n",
      prev = "[n",
      list = "]l",
      show = "]s",
      enter = "]e",
      follow = "]g",
      reply = "]r",
      autofloat = false,
      inline = false,
    },
  }
  T.eq(nil, group(), "no shared prefix")
  AgentNotes.setup()
end)

T.test("a key the user remapped since setup is left alone", function()
  AgentNotes.setup()
  vim.keymap.set("n", "<Leader>an", "<Cmd>echo 'mine'<CR>")
  AgentNotes.setup { keymaps = { next = "]n" } }
  T.eq("<Cmd>echo 'mine'<CR>", vim.fn.maparg("<Leader>an", "n"))
  vim.keymap.del("n", "<Leader>an")
  AgentNotes.setup()
end)

T.test("reload and setup() leave keys the user remapped or deleted since", function()
  AgentNotes.setup()
  vim.keymap.set("n", "<Leader>an", "<Cmd>echo 'mine'<CR>")
  vim.keymap.del("n", "<Leader>ar")
  vim.cmd "AgentNotes reload"
  AgentNotes.setup()
  T.eq("<Cmd>echo 'mine'<CR>", vim.fn.maparg("<Leader>an", "n"), "remapped key kept")
  T.eq("", vim.fn.maparg("<Leader>ar", "n"), "deleted key stays deleted")
  AgentNotes.setup { keymaps = { reply = "]r" } }
  T.eq("<Plug>(AgentNotesReply)", vim.fn.maparg("]r", "n"), "a new key for the action is mapped")
  vim.keymap.del("n", "<Leader>an")
  AgentNotes.setup { keymaps = { next = "]n" } }
  AgentNotes.setup()
  T.eq(DEFAULTS, mapped(), "back to the defaults once the user's key is gone")
end)

T.test("a buffer-local map on the same key does not keep a stale default", function()
  AgentNotes.setup()
  vim.keymap.set("n", "<Leader>an", "<Nop>", { buffer = true })
  AgentNotes.setup { keymaps = { next = "]n" } }
  vim.keymap.del("n", "<Leader>an", { buffer = true })
  T.eq(with { ["\\an"] = false, ["]n"] = { "<Plug>(AgentNotesNext)", "Next agent note" } }, mapped())
  AgentNotes.setup()
end)

T.test("replies = false leaves the reply key unmapped", function()
  AgentNotes.setup { replies = false }
  T.eq(with { ["\\ar"] = false }, mapped())
  AgentNotes.setup()
end)

T.test("reload re-applies the keymaps and they call the current module", function()
  AgentNotes.setup { keymaps = { next = "]n" } }
  vim.cmd "AgentNotes reload"
  T.eq(with { ["\\an"] = false, ["]n"] = { "<Plug>(AgentNotesNext)", "Next agent note" } }, mapped())
  local called = false
  local next = AgentNotes.next
  AgentNotes.next = function() called = true end
  vim.api.nvim_feedkeys(vim.keycode "]n", "x", false)
  AgentNotes.next = next
  T.ok(called, "]n called next")
  AgentNotes.setup()
end)

-- Starts nvim with an init.lua of lines, and returns the keys mapped once startup
-- has finished.
local function startup(lines)
  local dir = T.tmp .. "/startup"
  vim.fn.mkdir(dir, "p")
  local out = dir .. "/maps.json"
  os.remove(out)
  vim.fn.writefile(
    vim.list_extend(lines, {
      "vim.api.nvim_create_autocmd('VimEnter', { callback = function() vim.schedule(function()",
      ("  vim.fn.writefile({ vim.json.encode(dofile(%q)) }, %q) vim.cmd 'qall!'"):format(dir .. "/mapped.lua", out),
      "end) end })",
    }),
    dir .. "/init.lua"
  )
  vim.fn.writefile({
    "local out = {}",
    "for _, m in ipairs(vim.api.nvim_get_keymap 'n') do",
    "  if m.rhs and m.rhs:find('<Plug>(AgentNotes', 1, true) then out[vim.fn.keytrans(m.lhsraw)] = { m.rhs, m.desc } end",
    "end",
    "return out",
  }, dir .. "/mapped.lua")
  local r = vim
    .system({ vim.v.progpath, "--headless", "-i", "NONE", "-u", dir .. "/init.lua" }, { text = true })
    :wait(20000)
  T.eq(0, r.code, "nvim exit code: " .. r.stderr)
  return vim.json.decode(vim.fn.readfile(out)[1])
end

local RTP = "vim.opt.rtp:prepend(vim.env.NVIM_TEST_ROOT)"

T.test("without setup() the default keys are mapped at startup", function() T.eq(DEFAULTS, startup { RTP }) end)

T.test(
  "setup() in the config maps only its keys",
  function()
    T.eq(
      with { ["\\an"] = false, ["\\af"] = false, ["]n"] = { "<Plug>(AgentNotesNext)", "Next agent note" } },
      startup { RTP, "require('agent-notes').setup { keymaps = { next = ']n', autofloat = false } }" }
    )
  end
)

T.test(
  "setup() after the plugin file loads, as lazy.nvim calls it, leaves no stale defaults",
  function()
    T.eq(
      with { ["\\an"] = false, ["]n"] = { "<Plug>(AgentNotesNext)", "Next agent note" } },
      startup {
        RTP,
        "vim.cmd.runtime 'plugin/agent-notes.lua'",
        "require('agent-notes').setup { keymaps = { next = ']n' } }",
      }
    )
  end
)

T.test(
  "without setup() the user's config can override or delete a default key",
  function()
    T.eq(
      with { ["\\an"] = false, ["\\ar"] = false },
      startup {
        RTP,
        "vim.cmd.runtime 'plugin/agent-notes.lua'",
        "vim.keymap.set('n', '<Leader>an', '<Cmd>echo \\'mine\\'<CR>')",
        "vim.keymap.del('n', '<Leader>ar')",
      }
    )
  end
)

T.test("a plugin loaded after startup maps the defaults, or setup()'s keys", function()
  local late = {
    "vim.api.nvim_create_autocmd('VimEnter', { callback = function()",
    "  vim.opt.rtp:prepend(vim.env.NVIM_TEST_ROOT) vim.cmd.runtime 'plugin/agent-notes.lua'",
  }
  T.eq(DEFAULTS, startup(vim.list_extend(vim.deepcopy(late), { "end })" })))
  T.eq(
    with { ["\\an"] = false, ["]n"] = { "<Plug>(AgentNotesNext)", "Next agent note" } },
    startup(vim.list_extend(late, { "  require('agent-notes').setup { keymaps = { next = ']n' } } end })" }))
  )
end)

T.run()
