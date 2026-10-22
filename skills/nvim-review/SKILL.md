---
name: nvim-review
description: Show, walk through, and annotate code in a background Neovim session the user attaches to, through the nvim MCP server. Use when the user asks to be pointed at, shown, or walked through code, to see where something lives, to open a file, line, or location in nvim, or for an annotated code or PR review in nvim.
---

# Show and review code in nvim

Start a background nvim session with the user's config, set everything up in it with the `nvim` MCP tools from the agent-notes plugin, mainly `vim_command` (`vim_status` shows where the cursor is), then give the user one command to attach. Always start a session; do not look for an nvim the user already has open. The tools reach this agent's session once it is started, and other agents' sessions stay separate. Use absolute paths everywhere.

The plugin's scripts are `${CLAUDE_PLUGIN_ROOT}/bin/nvim-session`, `${CLAUDE_PLUGIN_ROOT}/bin/nvim-mcp` and `${CLAUDE_PLUGIN_ROOT}/bin/nvim-focus`. Run them by these full paths, since another copy earlier on `PATH` would win over the bare names.

## Start a session

1. Run `${CLAUDE_PLUGIN_ROOT}/bin/nvim-session start <dir>`, with the repository or worktree you are showing as `<dir>`. It starts a headless nvim there, waits until the user's config has loaded agent-notes.nvim, and prints the attach command. While the session runs, `start` only prints the command again. If it fails, pass on its message and print the locations as `/abs/path:line` instead.
2. Run `${CLAUDE_PLUGIN_ROOT}/bin/nvim-mcp --check` before the first nvim tool call. It prints the session's socket. A tool call made while no nvim is listening crashes the MCP server for the rest of the session; it comes back after `/mcp` reconnect or a new Claude session.
3. Read the user's agent-notes options: `lua print(vim.inspect(AgentNotes.config and AgentNotes.config()))`. Keep `replies` and `keymaps` for later. When it prints `nil`, the plugin is older than 0.3.0: replies are on and the keys are the defaults under [Keys](#keys). When `AgentNotes.viewed` is `nil`, the plugin is older than 0.4.0 and does not track viewed notes: skip [What the user has viewed](#what-the-user-has-viewed) and the `viewed=` field.
4. Do all the setup over MCP before you reply: open files, open channels (only when `replies` is on), load notes and `jump(1)`.
5. Give the user the attach command in a code block of its own and tell them the code is ready:

   ```sh
   nvim --remote-ui --server /abs/path/session-1234.sock
   ```

   Tell them that `:detach` (Neovim 0.11 or later) or closing the terminal leaves the session running (if `:detach` says "no current client", run it again), and `:qa` ends it.

### Recover a session

- The user detached or closed the terminal: the session keeps running with its notes. Run `nvim-session start <dir>` to print the command again and give it to them.
- The user quit, or the session exited: `nvim-mcp --check` fails with "this agent's nvim session has exited". Run `nvim-session start <dir>`, redo the setup and give them the new command. The old notes are gone, but reply channel files stay, so pass the same channel paths again.
- Restart with `nvim-session stop` and then `start` when the session is in a bad state, or to show a different directory, since `start` keeps a running session in its first directory. `stop` refuses while the session has unsaved changes or does not answer; ask the user before you run `stop --force`, which discards the changes or kills the nvim.
- `nvim-session list` shows every session: its id, whether it runs, attached UIs, whether its Claude Code process still runs, and its directory.

## Point at code

Open files from a normal file window: if `vim_status` shows the cursor in quickfix or a sidebar, move to a file window first (`wincmd p`, then check again). For a path with spaces, use `execute 'edit +42 ' .. fnameescape('/abs/a b.go')`.

- One location: `edit +<line> /abs/path`, then `normal! zz`.
- A few locations to step through without commentary: a new titled quickfix list, so the user's earlier lists stay reachable with `:colder`: `lua vim.fn.setqflist({}, ' ', {title = 'auth: token refresh', items = {{filename = '/abs/a.go', lnum = 42, text = 'refresh starts here'}, {filename = '/abs/b.go', lnum = 7, text = 'token cached here'}}})`, then `copen | cfirst`.
- Areas to compare side by side: `tabnew +<line> /abs/path`, or `vsplit +<line> /abs/path`.
- Select a range linewise with `normal! <start>GV<end>G`, or leave the cursor on its first line.

When you explain code or give opinions on it, annotate it instead (below). Never insert comments into the user's files.

## Annotate code

The agent-notes.nvim plugin shows each note as a sign plus wrapped virtual lines under its first line (only the sign with `display = "float"`), prefixed with its step (`3/10`) and coloured by kind. Notes follow their lines through edits and never change the file. The plugin loads at nvim startup and defines the global `AgentNotes`. When the user's config does not load it, `nvim-session start` fails: tell the user to install agent-notes.nvim in nvim, and print locations meanwhile.

Add one note per `vim_command`:

```
lua AgentNotes.add{file='/abs/a.go', line=42, end_line=48, kind='warn', text='Retries without backoff.\nCompare [[/abs/b.go:7|the client\'s retry]] and [[c.go:30]].'}
```

- `kind`: `info` for context that helps the user understand the code, `warn` for something the user may take issue with that is not clearly wrong, `issue` for something you are nearly certain is a problem.
- `end_line` is optional. The file need not be open. Add notes after you finish editing a file. If code changes while notes are shown, follow [Keep notes in place when code changes](#keep-notes-in-place-when-code-changes).
- Links are `[[path:line]]` or `[[path:line|label]]`, absolute or relative to nvim's cwd.
- Notes read in call order across files; `order=<n>` places one explicitly (equal orders keep call order). Step numbers renumber as notes are added or cleared.
- Each command is one line. Use single-quoted Lua strings with `\n` for line breaks, `\'` for quotes and `\\` for backslashes. Do not use `[[...]]` Lua strings. For many notes, load them from JSON instead (see PR walkthroughs).
- A bad kind, path, line or link target makes `add` fail with an error and adds nothing. Then run `lua AgentNotes.summary()`: one line per note with step, `#id`, kind, location and links.
- `lua AgentNotes.jump(1)` shows the first note. Run it last, before you give the user the attach command. With `display = "inline"` it does not open the float; the note shows under its line.

### Write notes the user can read

Write each note in plain spoken English, the way you would explain the code to a colleague at their desk. When `teach`, `how`, `why` or `unslop` skills are available, follow `teach` for how to explain, `how` for what the code does at runtime, `why` for the reasons behind it, and `unslop` for the prose. Run their workflows only when you lack those facts, not once per note. Notes are plain text, so skip diagrams and offers to go deeper.

- Lead with what this code does and why it matters, in plain words. Mechanics come after, and only the ones the user needs.
- One idea per note. A note that covers several behaviours becomes several notes, each on the line that does that thing, in reading order.
- Short sentences. Split a sentence that chains clauses or names more than two identifiers.
- Name the concrete case that hits this line, such as "when the cache is empty on the first request".
- Say how it connects to the previous note or to what the user already knows. Do not assume the user has read the code around it.
- Define an internal term on first use, or say it plainly instead. Backtick an identifier only when the user needs the name to find it.
- `warn` and `issue` notes state the risk plainly first, then the scenario that triggers it and what goes wrong.

## What the user has viewed

Do not assume the user read your notes. The plugin marks a note viewed when, with the user attached, they step to it, pick it in the notes list, follow a link to it, open its float or chat, or rest the cursor on its lines for a second while its text shows. Your own `jump` before they attach does not count; a `jump` or `edit` after they attach does, since it puts the note in front of them.

- `lua AgentNotes.viewed()` prints `viewed: #3 #5` and `unviewed: #7`, ids in reading order. `summary()` marks each line `[viewed]` or `[unviewed]`.
- The first view of a note with a channel appends `{"type":"view", "note", "order", "file", "line", "excerpt", "time"}` to the channel file, so you can read it after the session ends. The reply Monitor's `"type":"reply"` filter skips these lines.
- Check before you wrap up, when the user says they are done, and when they ask. Name the unviewed notes by step and first line, and offer to step through them, instead of treating the review as read.

## Keep notes in place when code changes

Notes track edits made in nvim, but not changes on disk: a reloaded buffer keeps its notes on their old line numbers. Whenever you or a worker you delegate to change code while a review session is open, re-place the notes before you reply to the user:

1. If the session shows a PR worktree, move it to the new revision: `git -C <worktree> checkout --detach <new sha>`.
2. Reload the unmodified buffers: `lua for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == '' and not vim.bo[b].modified then vim.cmd.checktime(b) end end`. This needs `autoread`, which is on by default. Tell the user about a changed file whose buffer has unsaved changes instead of reloading it.
3. Read the notes with `lua print(vim.json.encode(AgentNotes.list()))` and keep each one's `text`, `kind`, `order` and `viewed`, plus the channel you gave it.
4. For every note in a changed file, find its code in the new file and recompute `line` and `end_line`. Check notes outside the edited hunks too, since lines added or removed above them shift them. If the change altered what a note describes, rewrite its text, or drop it if it no longer applies. Recompute `[[path:line]]` links into changed files too, in every note.
5. `clear` those notes and add them again with the new lines, passing `viewed=true` for notes the user had viewed and the same `channel`. Then `summary()` to check them. Re-added notes get new ids and lose their threads, so map a later reply's old id to the new one before you `respond`.

## PR walkthroughs

1. Check out the PR head in a detached worktree so line numbers match: `git -C <repo> fetch origin pull/<n>/head` and `git -C <repo> worktree add --detach <repo>/.worktrees/pr-<n> FETCH_HEAD` (check that `.worktrees/` is ignored). Record the head SHA you review (`git -C <worktree> rev-parse HEAD`); the next round diffs from it.
2. Start the session in the worktree: `${CLAUDE_PLUGIN_ROOT}/bin/nvim-session start <repo>/.worktrees/pr-<n>`.
3. Delegate the analysis to a subagent. Give it the PR, the worktree path and the base (for a later round, the range under [Later rounds](#later-rounds)), and ask for a JSON array of notes (`file` as an absolute path in the worktree, `line`, optional `end_line`, `kind`, `text`, optional `order`), each verified against the worktree file, in reading order. Optional keys are omitted or `null`. Paste the bullets from "Write notes the user can read" into its prompt. When the `teach` and `unslop` skills are available, tell it to load them for how to write, and to use `how` or `why` only for a fact the diff and PR body do not show, keeping `why` to git history and the PR's linked ticket.
4. Write the JSON to a file in your scratchpad, open a reply channel if the user may want to answer and replies are on (below), and load all notes in one call: `lua for _, n in ipairs(vim.json.decode(table.concat(vim.fn.readfile('<json>'), '\n'))) do n.channel = '<channel path>'; AgentNotes.add(n) end`. Omit `n.channel = ...` without a channel. Then `summary()` and `jump(1)`, and give the user the attach command.
5. When the walkthrough is over, wrap up (below), then `git -C <repo> worktree remove <repo>/.worktrees/pr-<n>`.

### Later rounds

When the user asks for another round after the code changed, review only what changed since the last round, not the whole PR again.

1. Fetch the new head in the worktree and move it there: `git -C <worktree> fetch origin pull/<n>/head` and `git -C <worktree> checkout --detach FETCH_HEAD`. Then reposition the earlier notes as in [Keep notes in place when code changes](#keep-notes-in-place-when-code-changes). Clear them instead if the user prefers.
2. Give the subagent the range `<last reviewed sha>..<new sha>` as its base and head, and ask for notes only on that diff. It writes them the same way, against the worktree files. If the PR was rebased, that diff also holds the base branch's changes; tell the subagent to compare with `git range-diff <old base>..<last reviewed sha> <new base>..<new sha>` and note only the PR's own changes.
3. Add the new notes after the existing ones (drop their `order`, or offset it past the last note's), then `jump` to the first new note. Record the new head SHA as the base of the next round.

## Replies

The user can answer any note that has a channel; each reply wakes you.

Skip this section when `AgentNotes.config().replies` is `false`: do not open a channel, pass `channel=` or start the Monitor. `channel()` raises "replies are off" then, and `add` ignores `channel=`. `respond()` still shows an answer in the note's thread, but the user cannot write to you from nvim, so ask in the conversation instead.

1. `lua AgentNotes.channel()` prints a new channel file's path (your own path must end in `.jsonl`). Pass it as `channel='<path>'` to each `add`. Channels are per note, so other sessions' notes keep theirs.
2. Start the `Monitor` tool (load it with ToolSearch `select:Monitor` if deferred) on `tail -n0 -F <path> | grep --line-buffered '"type":"reply"'` with the longest timeout (30 minutes). Re-arm it when it expires while the walkthrough is still going.
3. Each event is one JSON line: `type` (`reply`; the file also gets `view` and `response` lines, which the filter skips), `note` (id), `order` (its step number), `file`, `line`, `excerpt` (the note's first line), `text` (the user's message), `time`.
4. Answer with `lua AgentNotes.respond(<note id>, 'text')`, quoted like `add`; ids are the `#n` in `summary()`. It appears in the user's chat window and the note float, and notifies the user. Write answers the same way as notes. You can also add or re-add notes.
5. `lua AgentNotes.replies('<path>')` prints the user's replies to your notes if you need to catch up.

## Diff view

Stepping works inside a gitsigns diff (`:Gitsigns diffthis`, against the index or any revision): the note's line comes up on the working side and the revision side follows. A note in another file re-opens the diff for that file against the same revision; untracked files and files outside git get a plain jump, and the diff comes back on the next tracked note. The revision side gets blank lines across from each note, kept level while either side scrolls, so rows below a note stay aligned with their counterpart.

## Keys

The first time you add notes in a session, tell the user the keys. These are the defaults. Use the keys in `AgentNotes.config().keymaps` instead (`keymaps` is `false` when the user maps none), leave out an entry that is `false`, and leave out `<Leader>ar` when replies are off.

- `<Leader>an` / `<Leader>ap`: next or previous note, wrapping at either end.
- `<Leader>af`: toggle whether stepping opens the note float, for this session. `display` in the user's config sets where it starts: on for `both` and `float`, off for `inline`.
- `<Leader>ai`: toggle the note text under each line, for this session; the sign stays. Off at the start with `display = "float"`.
- `<Leader>as`: toggle the note float for the cursor line. `<Leader>ae`: enter it (to scroll or use links).
- `<Leader>ag`: follow a note's link, with a picker for several. `<CR>` on a link in the float does the same.
- `<Leader>ar`: open the chat for the note: the note and its thread above, input below. Ctrl+Enter or `<C-s>` sends and keeps the chat open; `<CR>` is a newline; `q` or `<Esc>` in normal mode closes it. Only notes with a channel accept replies.
- `<Leader>al`: the notes list, its own quickfix list; the user's earlier lists stay reachable with `:colder`.

`:AgentNotes` takes `next`, `prev`, `list`, `show`, `enter`, `follow`, `reply`, `replies`, `autofloat`, `inline`, `summary`, `viewed`, `clear` and `reload`.

## Wrap up

Before you end a walkthrough, check `AgentNotes.viewed()` and tell the user about any unviewed notes (see [What the user has viewed](#what-the-user-has-viewed)).

When the walkthrough is over, stop the monitor and run `${CLAUDE_PLUGIN_ROOT}/bin/nvim-session stop`, unless the user wants to keep the session. If it refuses because of unsaved changes, tell the user and let them save, or ask before `stop --force`. A session nobody stops quits on its own once this Claude Code process has exited and no UI has been attached for 30 minutes; `nvim-session list` shows leftovers, and `nvim-session stop <id>` ends one.

If the user keeps the session but not your notes, clear them: `lua AgentNotes.clear{channel='<path>'}` with a channel, otherwise `clear('/abs/file')` per file.

## Switch the user's view

Once the user has attached, run `${CLAUDE_PLUGIN_ROOT}/bin/nvim-focus` after showing new code, so herdr switches to the pane where they attached. When they are not attached in a pane of this herdr workspace, or you are not in herdr, it only prints a note and changes nothing: tell them the code is ready in the session. If it fails, pass on its message.

## Limits

- Do not edit, save, or close the user's buffers, windows, or tabs unless the user explicitly asks; the user can edit in the session too. End the session with `nvim-session stop`, not `:qa` through the tools. `AgentNotes` is the exception: it loads files and opens floats, the chat and the notes list, but never changes buffer text. Do not use `vim_edit`, `vim_buffer_save`, `vim_search_replace`, or `vim_macro`.
- Do not run shell commands through nvim (`!`, `system()`, `:terminal`, `os.execute`, `jobstart`).
