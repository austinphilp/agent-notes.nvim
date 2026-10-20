-- A minimal test runner for the specs: each spec calls T.test(name, fn) and ends
-- with T.run(), which prints one line per test and exits nvim non-zero on failure.
local T = { tests = {} }

T.tmp = vim.env.NVIM_TEST_TMP

function T.test(name, fn) T.tests[#T.tests + 1] = { name = name, fn = fn } end

function T.eq(want, got, what)
  if not vim.deep_equal(want, got) then
    error(("%s: expected %s, got %s"):format(what or "value", vim.inspect(want), vim.inspect(got)), 2)
  end
end

function T.ok(value, what)
  if not value then error((what or "assertion") .. " failed", 2) end
end

--- Asserts that fn raises an error whose message contains needle.
function T.raises(needle, fn)
  local ok, err = pcall(fn)
  if ok then error(("expected an error containing %q"):format(needle), 2) end
  if not tostring(err):find(needle, 1, true) then error(("expected error %q, got %q"):format(needle, err), 2) end
end

--- Writes lines to a new file under the test's temp dir and returns its real path.
function T.file(name, lines)
  local path = T.tmp .. "/files/" .. name
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  return vim.uv.fs_realpath(path)
end

-- Quiet the API's print and notify output so test results stay readable.
T.messages = {}
_G.print = function(...) T.messages[#T.messages + 1] = table.concat(vim.tbl_map(tostring, { ... }), " ") end
vim.notify = function(msg) T.messages[#T.messages + 1] = msg end

function T.run()
  local failed = 0
  local spec = vim.fn.fnamemodify(debug.getinfo(2, "S").source:sub(2), ":t")
  for _, t in ipairs(T.tests) do
    AgentNotes.clear()
    local ok, err = xpcall(t.fn, debug.traceback)
    io.stdout:write(("%s %s: %s\n"):format(ok and "ok  " or "FAIL", spec, t.name))
    if not ok then
      failed = failed + 1
      io.stdout:write(err, "\n")
    end
  end
  io.stdout:write(("%s: %d passed, %d failed\n"):format(spec, #T.tests - failed, failed))
  vim.cmd(failed > 0 and "cquit 1" or "qall!")
end

return T
