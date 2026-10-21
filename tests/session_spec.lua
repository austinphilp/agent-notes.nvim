local T = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helpers.lua")

local root = vim.env.NVIM_TEST_ROOT
local cache = vim.fn.stdpath "cache"
local default = cache .. "/default.sock"

-- Session nvims load this config, like a user's that sets up agent-notes.nvim with
-- socket = true.
local config = vim.env.XDG_CONFIG_HOME .. "/nvim"
vim.fn.mkdir(config, "p")
vim.fn.writefile({
  "vim.opt.rtp:prepend(vim.env.NVIM_TEST_ROOT)",
  'require("agent-notes").setup { socket = true }',
}, config .. "/init.lua")

-- The agent whose sessions most tests use: this nvim, which outlives them. Sessions
-- left by a failing test quit once it exits, after NVIM_SESSION_IDLE.
local agent = vim.fn.getpid()

local function run(cmd, env)
  local r = vim.system(cmd, { env = env, text = true }):wait(90000)
  return r.code, r.stdout, r.stderr
end

--- Runs bin/nvim-session for agent pid id.
local function session(id, args, env)
  local cmd = vim.list_extend({ root .. "/bin/nvim-session" }, args)
  return run(cmd, vim.tbl_extend("force", { CLAUDE_PID = tostring(id), NVIM_SESSION_IDLE = "2" }, env or {}))
end

local function socket_of(id) return ("%s/session-%d.sock"):format(cache, id) end

--- Evaluates a Vim expression in the nvim on sock, or runs Lua with lua = true.
local function rpc(sock, code, lua)
  local chan = vim.fn.sockconnect("pipe", sock, { rpc = true })
  local ok, result
  if lua then
    ok, result = pcall(vim.rpcrequest, chan, "nvim_exec_lua", code, {})
  else
    ok, result = pcall(vim.rpcrequest, chan, "nvim_eval", code)
  end
  vim.fn.chanclose(chan)
  if not ok then error(result, 2) end
  return result
end

local function pid_alive(pid) return vim.uv.kill(pid, 0) == 0 end

--- Starts a session for agent id in dir and returns its socket and nvim pid.
local function start(id, dir)
  local code, out, err = session(id, { "start", dir or T.tmp })
  T.eq(0, code, "start exit code: " .. err)
  local sock = socket_of(id)
  T.eq(("nvim --remote-ui --server %s\n"):format(sock), out, "attach command")
  return sock, rpc(sock, "getpid()")
end

--- Like T.test, but ends every session the test leaves, so one failure does not
--- spill into the next tests.
local function test(name, fn)
  T.test(name, function()
    local ok, err = pcall(fn)
    for _, info in ipairs(vim.fn.glob(cache .. "/session-*.info", false, true)) do
      session(agent, { "stop", "--force", info:match "session%-(%d+)%.info$" })
    end
    if not ok then error(err, 0) end
  end)
end

--- A live pid that is not this nvim, for a second agent. Jobs end with this nvim.
local function other_agent() return vim.fn.jobpid(vim.fn.jobstart { "sleep", "120" }) end

test("start waits for the plugin and prints the attach command", function()
  local dir = T.file("repo/a.go", { "package a" }):match "(.*)/"
  local sock = start(agent, dir)
  T.eq(dir, rpc(sock, "getcwd()"), "cwd")
  T.eq(1, rpc(sock, "v:vim_did_enter"), "entered")
  T.eq(true, rpc(sock, 'luaeval("AgentNotes ~= nil")'), "plugin loaded")
  T.ok(not vim.uv.fs_stat(default), "the session leaves the shared socket alone")

  local code, out, err = session(agent, { "start", "/" })
  T.eq(0, code, "second start exit code")
  T.eq(("nvim --remote-ui --server %s\n"):format(sock), out, "same attach command")
  T.ok(err:find("already running in " .. dir, 1, true), err)
  session(agent, { "stop" })
end)

test("list shows sessions and stop ends them and removes their files", function()
  local sock, pid = start(agent)
  local _, out = session(agent, { "list" })
  T.ok(out:find(("%d%%s+running%%s+0%%s+running.*%s %%(this agent%%)"):format(agent, vim.pesc(vim.uv.fs_realpath(T.tmp)))), out)

  local code, stopped = session(agent, { "stop" })
  T.eq(0, code, "stop exit code")
  T.eq(("nvim-session: stopped session %d\n"):format(agent), stopped)
  T.ok(not pid_alive(pid), "nvim exited")
  T.eq({}, vim.fn.glob(cache .. "/session-*", false, true), "files removed")
  _, out = session(agent, { "list" })
  T.eq("nvim-session: no sessions\n", out)
  T.ok(not vim.uv.fs_stat(sock), "socket removed")
end)

test("stop keeps a session with unsaved changes unless forced", function()
  local sock, pid = start(agent)
  rpc(sock, ("vim.cmd.edit(%q) vim.api.nvim_buf_set_lines(0, 0, -1, true, { 'draft' })"):format(T.tmp .. "/new.txt"), true)
  local code, _, err = session(agent, { "stop" })
  T.eq(1, code, "stop exit code")
  T.ok(err:find("1 buffer(s) with unsaved changes", 1, true), err)
  T.ok(pid_alive(pid), "still running")
  T.eq(0, (session(agent, { "stop", "--force" })), "forced stop exit code")
  T.ok(not pid_alive(pid), "nvim exited")
end)

test("start fails clearly when nvim does not come up with the plugin", function()
  local empty = T.tmp .. "/empty-config"
  vim.fn.mkdir(empty .. "/nvim", "p")
  local code, out, err = session(agent, { "start" }, { XDG_CONFIG_HOME = empty })
  T.eq(1, code, "exit code")
  T.eq("", out, "no attach command")
  T.ok(err:find("its config does not load agent-notes.nvim", 1, true), err)
  T.eq({}, vim.fn.glob(cache .. "/session-*", false, true), "files removed")

  vim.fn.writefile({ "vim.cmd.cquit()" }, empty .. "/nvim/init.lua")
  code, _, err = session(agent, { "start" }, { XDG_CONFIG_HOME = empty })
  T.eq(1, code, "exit code")
  T.ok(err:find("nvim exited during startup", 1, true), err)
  T.eq({}, vim.fn.glob(cache .. "/session-*", false, true), "files removed")
end)

test("an attached UI shows the notes the agent adds", function()
  local file = T.file("ui.go", { "package ui", "", "func Run() {}" })
  local sock = start(agent)
  local screen, exited = "", false
  vim.fn.jobstart({ "nvim", "--remote-ui", "--server", sock }, {
    pty = true,
    width = 100,
    height = 30,
    on_stdout = function(_, data) screen = screen .. table.concat(data, "") end,
    on_exit = function() exited = true end,
  })
  T.ok(vim.wait(10000, function() return rpc(sock, "len(nvim_list_uis())") == 1 end), "UI attached")
  rpc(sock, ("AgentNotes.add { file = %q, line = 3, text = 'Run starts the loop' } AgentNotes.jump(1)"):format(file), true)
  T.ok(vim.wait(10000, function() return screen:find("Run starts the loop", 1, true) ~= nil end), "note rendered")
  session(agent, { "stop" })
  T.ok(vim.wait(5000, function() return exited end), "UI exits with the session")
end)

test("each agent's MCP tools reach only its own session", function()
  local other = other_agent()
  local sock_a, sock_b = start(agent), start(other)
  rpc(sock_a, "vim.g.owner = 'a'", true)
  T.eq(0, rpc(sock_b, "exists('g:owner')"), "sessions are separate nvims")

  local mcp = root .. "/bin/nvim-mcp"
  T.eq(sock_a .. "\n", select(2, run({ mcp, "--check" }, { CLAUDE_PID = tostring(agent) })), "agent a")
  T.eq(sock_b .. "\n", select(2, run({ mcp, "--check" }, { CLAUDE_PID = tostring(other) })), "agent b")

  -- The server keys on its parent process, here this nvim, which stands in for the
  -- Claude Code process. Fake npx and server print the socket the resolver answers
  -- for each line they read, so the answer is checked per call like a tool call.
  local bin = T.tmp .. "/fakebin"
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({ "#!/usr/bin/env bash", 'while [[ "$1" != -c ]]; do shift; done', 'exec bash -c "$2"' }, bin .. "/npx")
  vim.fn.writefile({
    "#!/usr/bin/env node",
    'process.stdin.on("data", () => console.log(process.env.NVIM_SOCKET_PATH));',
  }, bin .. "/mcp-neovim-server")
  vim.fn.setfperm(bin .. "/npx", "rwxr-xr-x")
  vim.fn.setfperm(bin .. "/mcp-neovim-server", "rwxr-xr-x")
  local answers = {}
  local server = vim.system({ mcp }, {
    stdin = true,
    env = { PATH = bin .. ":" .. vim.env.PATH, CLAUDE_PID = "" },
    stdout = function(_, data)
      if data then vim.list_extend(answers, vim.split(vim.trim(data), "\n")) end
    end,
  })
  local function ask(n)
    server:write "\n"
    T.ok(vim.wait(10000, function() return #answers >= n end), "server answered")
    return answers[n]
  end

  T.eq(sock_a, ask(1), "server for agent a")
  session(agent, { "stop" })
  T.eq(default, ask(2), "falls back once agent a's session is stopped")
  start(agent)
  T.eq(sock_a, ask(3), "follows a session started after the server")
  server:write(nil)
  server:wait(5000)
  session(agent, { "stop" })
  session(other, { "stop" })
end)

test("without a session the tools use the shared socket", function()
  local code, out = run({ root .. "/bin/nvim-mcp", "--socket-path" }, { CLAUDE_PID = tostring(agent) })
  T.eq(0, code, "exit code")
  T.eq(default .. "\n", out)
end)

--- The pid of an agent that has exited.
local function dead_agent()
  local job = vim.system { "true" }
  job:wait()
  T.ok(not pid_alive(job.pid), "agent exited")
  return job.pid
end

test("an orphaned session with unsaved changes keeps running", function()
  local dead = dead_agent()
  local sock, pid = start(dead)
  local file = T.tmp .. "/kept.txt"
  -- With 'confirm', a headless :qall would save the buffer instead of failing.
  rpc(sock, ("vim.o.confirm = true vim.cmd.edit(%q) vim.api.nvim_buf_set_lines(0, 0, -1, true, { 'draft' })"):format(file), true)
  vim.wait(4000)
  T.ok(pid_alive(pid), "still running")
  T.ok(not vim.uv.fs_stat(file), "nothing saved")
  session(agent, { "stop", "--force", tostring(dead) })
end)

test("stop --force kills a session that no longer answers", function()
  local _, pid = start(agent)
  vim.uv.kill(pid, "sigstop")
  local code, _, err = session(agent, { "stop" })
  T.eq(1, code, "stop exit code")
  T.ok(err:find("is running but does not answer", 1, true), err)
  T.ok(pid_alive(pid), "not killed without --force")
  local out
  code, out, err = session(agent, { "stop", "--force" })
  T.eq(0, code, "stop exit code")
  T.eq(("nvim-session: stopped session %d\n"):format(agent), out)
  T.eq("", err, "no shell noise")
  T.ok(vim.wait(2000, function() return not pid_alive(pid) end), "nvim killed")
end)

test("stop leaves alone a process that reused a session's pid", function()
  local other = vim.fn.jobstart { "nvim", "--clean", "--headless" }
  local pid = vim.fn.jobpid(other)
  vim.fn.mkdir(cache, "p")
  vim.fn.writefile({ "pid=" .. pid, "dir=/", "started=then" }, ("%s/session-%d.info"):format(cache, agent))
  T.eq(0, (session(agent, { "stop" })), "stop exit code")
  T.ok(pid_alive(pid), "the other nvim still runs")
  T.eq({}, vim.fn.glob(cache .. "/session-*", false, true), "files removed")
  vim.fn.jobstop(other)
end)

test("a session quits once its agent has exited and no UI is attached", function()
  local dead = dead_agent()
  local _, pid = start(dead)
  T.ok(vim.wait(15000, function() return not pid_alive(pid) end, 200), "session quit")

  local _, out = session(dead, { "list" })
  T.ok(out:find(("%d%%s+exited%%s+%%-%%s+exited"):format(dead)), out)
  local code, _, err = run({ root .. "/bin/nvim-mcp", "--check" }, { CLAUDE_PID = tostring(dead) })
  T.eq(1, code, "check exit code")
  T.ok(err:find("this agent's nvim session has exited", 1, true), err)
  T.eq(0, (session(agent, { "stop", tostring(dead) })), "stop by id")
  T.eq({}, vim.fn.glob(cache .. "/session-*", false, true), "files removed")
end)

T.run()
