---
name: nvim-review
description: Show, walk through, and annotate code in the user's running Neovim through the nvim MCP server. Use when the user asks to be pointed at, shown, or walked through code, to see where something lives, to open a file, line, or location in nvim, or for an annotated code or PR review in nvim.
---

# Show and review code in nvim

Drive the user's running nvim with the `nvim` MCP tools from the agent-notes plugin, mainly `vim_command`; `vim_status` shows where the user is. Inside herdr they reach the nvim in this herdr workspace when one is running; otherwise they reach the nvim the user started outside herdr. Use absolute paths everywhere.

The plugin's scripts are `${CLAUDE_PLUGIN_ROOT}/bin/nvim-mcp` and `${CLAUDE_PLUGIN_ROOT}/bin/nvim-focus`. Run them by these full paths, since another copy earlier on `PATH` would win over the bare names.

## Check first

Run `${CLAUDE_PLUGIN_ROOT}/bin/nvim-mcp --check` before the first nvim tool call of a task. It prints the socket of the nvim the tools will reach. A tool call made while no nvim is listening crashes the MCP server for the rest of the session.

If the check fails, or the nvim tools are missing or erroring, print the locations as `/abs/path:line` and tell the user to start nvim (in this herdr workspace when they use herdr), or to switch to a running nvim so it takes over the socket. The nvim needs agent-notes.nvim with `socket = true`, or must listen on the printed path. A crashed server comes back after `/mcp` reconnect or a new Claude session.

## Point at code

Open files from a normal file window: if `vim_status` shows the cursor in quickfix or a sidebar, move to a file window first (`wincmd p`, then check again). For a path with spaces, use `execute 'edit +42 ' .. fnameescape('/abs/a b.go')`.

- One location: `edit +<line> /abs/path`, then `normal! zz`.
- A few locations to step through without commentary: a new titled quickfix list, so the user's earlier lists stay reachable with `:colder`: `lua vim.fn.setqflist({}, ' ', {title = 'auth: token refresh', items = {{filename = '/abs/a.go', lnum = 42, text = 'refresh starts here'}, {filename = '/abs/b.go', lnum = 7, text = 'token cached here'}}})`, then `copen | cfirst`.
- Areas to compare side by side: `tabnew +<line> /abs/path`, or `vsplit +<line> /abs/path`.
- Select a range linewise with `normal! <start>GV<end>G`, or leave the cursor on its first line.

When you explain code or give opinions on it, annotate it instead (below). Never insert comments into the user's files.

## Annotate code

The agent-notes.nvim plugin shows each note as a sign plus wrapped virtual lines under its first line, prefixed with its step (`3/10`) and coloured by kind. Notes follow their lines through edits and never change the file. The plugin loads at nvim startup and defines the global `AgentNotes`. If `lua print(AgentNotes ~= nil)` prints `false`, tell the user to install agent-notes.nvim in nvim, and point at code without notes meanwhile.

Add one note per `vim_command`:

```
lua AgentNotes.add{file='/abs/a.go', line=42, end_line=48, kind='warn', text='Retries without backoff.\nCompare [[/abs/b.go:7|the client\'s retry]] and [[c.go:30]].'}
```

- `kind`: `info` for context that helps the user understand the code, `warn` for something the user may take issue with that is not clearly wrong, `issue` for something you are nearly certain is a problem.
- `end_line` is optional. The file need not be open. Add notes after you finish editing a file. If it changes on disk, clear its notes and add them again, because a reload keeps notes on their old line numbers.
- Links are `[[path:line]]` or `[[path:line|label]]`, absolute or relative to nvim's cwd.
- Notes read in call order across files; `order=<n>` places one explicitly (equal orders keep call order). Step numbers renumber as notes are added or cleared.
- Each command is one line. Use single-quoted Lua strings with `\n` for line breaks, `\'` for quotes and `\\` for backslashes. Do not use `[[...]]` Lua strings. For many notes, load them from JSON instead (see PR walkthroughs).
- A bad kind, path, line or link target makes `add` fail with an error and adds nothing. Then run `lua AgentNotes.summary()`: one line per note with step, `#id`, kind, location and links.
- `lua AgentNotes.jump(1)` shows the first note; run `nvim-focus` afterwards (see below).

### Write notes the user can read

Write each note in plain spoken English, the way you would explain the code to a colleague at their desk. When `teach`, `how`, `why` or `unslop` skills are available, follow `teach` for how to explain, `how` for what the code does at runtime, `why` for the reasons behind it, and `unslop` for the prose. Run their workflows only when you lack those facts, not once per note. Notes are plain text, so skip diagrams and offers to go deeper.

- Lead with what this code does and why it matters, in plain words. Mechanics come after, and only the ones the user needs.
- One idea per note. A note that covers several behaviours becomes several notes, each on the line that does that thing, in reading order.
- Short sentences. Split a sentence that chains clauses or names more than two identifiers.
- Name the concrete case that hits this line, such as "when the cache is empty on the first request".
- Say how it connects to the previous note or to what the user already knows. Do not assume the user has read the code around it.
- Define an internal term on first use, or say it plainly instead. Backtick an identifier only when the user needs the name to find it.
- `warn` and `issue` notes state the risk plainly first, then the scenario that triggers it and what goes wrong.

## PR walkthroughs

1. Check out the PR head in a detached worktree so line numbers match: `git -C <repo> fetch origin pull/<n>/head` and `git -C <repo> worktree add --detach <repo>/.worktrees/pr-<n> FETCH_HEAD` (check that `.worktrees/` is ignored).
2. Delegate the analysis to a subagent. Give it the PR, the worktree path and the base, and ask for a JSON array of notes (`file` as an absolute path in the worktree, `line`, optional `end_line`, `kind`, `text`, optional `order`), each verified against the worktree file, in reading order. Optional keys are omitted or `null`. Paste the bullets from "Write notes the user can read" into its prompt. When the `teach` and `unslop` skills are available, tell it to load them for how to write, and to use `how` or `why` only for a fact the diff and PR body do not show, keeping `why` to git history and the PR's linked ticket.
3. Write the JSON to a file in your scratchpad, open a reply channel if the user may want to answer (below), and load all notes in one call: `lua for _, n in ipairs(vim.json.decode(table.concat(vim.fn.readfile('<json>'), '\n'))) do n.channel = '<channel path>'; AgentNotes.add(n) end`. Omit `n.channel = ...` without a channel. Then `summary()`, `jump(1)` and `nvim-focus`.
4. When the walkthrough is over, clear your notes (below) and `git -C <repo> worktree remove <repo>/.worktrees/pr-<n>`.

## Replies

The user can answer any note that has a channel; each reply wakes you.

1. `lua AgentNotes.channel()` prints a new channel file's path (your own path must end in `.jsonl`). Pass it as `channel='<path>'` to each `add`. Channels are per note, so other sessions' notes keep theirs.
2. Start the `Monitor` tool (load it with ToolSearch `select:Monitor` if deferred) on `tail -n0 -F <path> | grep --line-buffered '"type":"reply"'` with the longest timeout (30 minutes). Re-arm it when it expires while the walkthrough is still going.
3. Each event is one JSON line: `type` (`reply`), `note` (id), `order` (its step number), `file`, `line`, `excerpt` (the note's first line), `text` (the user's message), `time`.
4. Answer with `lua AgentNotes.respond(<note id>, 'text')`, quoted like `add`; ids are the `#n` in `summary()`. It appears in the user's chat window and the note float, and notifies the user. Write answers the same way as notes. You can also add or re-add notes.
5. `lua AgentNotes.replies('<path>')` prints the user's replies to your notes if you need to catch up.

## Diff view

Stepping works inside a gitsigns diff (`:Gitsigns diffthis`, against the index or any revision): the note's line comes up on the working side and the revision side follows. A note in another file re-opens the diff for that file against the same revision; untracked files and files outside git get a plain jump, and the diff comes back on the next tracked note. The revision side gets blank lines across from each note, kept level while either side scrolls, so rows below a note stay aligned with their counterpart.

## Keys

The first time you add notes in a session, tell the user the keys:

- `<Leader>an` / `<Leader>ap`: next or previous note, wrapping at either end.
- `<Leader>af`: toggle whether stepping opens the note float (on by default).
- `<Leader>as`: toggle the note float for the cursor line. `<Leader>ae`: enter it (to scroll or use links).
- `<Leader>ag`: follow a note's link, with a picker for several. `<CR>` on a link in the float does the same.
- `<Leader>ar`: open the chat for the note: the note and its thread above, input below. Ctrl+Enter or `<C-s>` sends and keeps the chat open; `<CR>` is a newline; `q` or `<Esc>` in normal mode closes it. Only notes with a channel accept replies.
- `<Leader>al`: the notes list, its own quickfix list; the user's earlier lists stay reachable with `:colder`.

`:AgentNotes` takes `next`, `prev`, `list`, `show`, `enter`, `follow`, `reply`, `replies`, `autofloat`, `summary`, `clear` and `reload`.

## Clear

When the walkthrough is over, stop the monitor and clear your notes unless the user wants to keep them: `lua AgentNotes.clear{channel='<path>'}` with a channel, otherwise `clear('/abs/file')` per file. `clear()` and `clear(file)` also remove other sessions' notes.

## Then switch the user's view

Run `${CLAUDE_PLUGIN_ROOT}/bin/nvim-focus` after showing code so herdr switches to the nvim pane. When that nvim is not in a pane of this herdr workspace, or you are not in herdr, it only prints a note and changes nothing: tell the user the code is ready in nvim. If it fails, pass on its message.

## Limits

- Do not edit, save, or close the user's buffers, windows, or tabs unless the user explicitly asks. `AgentNotes` is the exception: it loads files and opens floats, the chat and the notes list, but never changes buffer text. Do not use `vim_edit`, `vim_buffer_save`, `vim_search_replace`, or `vim_macro`.
- Do not run shell commands through nvim (`!`, `system()`, `:terminal`, `os.execute`, `jobstart`).
