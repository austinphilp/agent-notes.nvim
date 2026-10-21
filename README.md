# agent-notes.nvim

agent-notes.nvim lets a coding agent point at code in Neovim and annotate it. Each note shows as a sign plus wrapped virtual lines under the line it is about, coloured by kind. Notes follow their lines through edits and never change the file. You step through notes in reading order, follow links between them, and reply to the agent from a chat window.

The repository is two plugins:

- A Neovim plugin, installed with lazy.nvim or any plugin manager. It provides the `AgentNotes` Lua API, the `:AgentNotes` command and the `<Leader>a` keymaps. Any agent that can run Lua in your nvim can use it.
- A Claude Code plugin named `agent-notes`. It ships an `nvim` MCP server, a launcher for background nvim sessions, and the `nvim-review` skill, which tells Claude how to show code, annotate it and read your replies.

## Requirements

- Neovim 0.10 or later.
- For the Claude Code plugin: Claude Code 2.1.214 or later, Perl, and Node.js with `npx`, which runs [`mcp-neovim-server`](https://github.com/bigcodegen/mcp-neovim-server) 0.5.5.
- Optional: [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim), so stepping through notes stays inside a gitsigns diff view. Optional: [which-key.nvim](https://github.com/folke/which-key.nvim), which shows the `<Leader>a` group as "Agent notes".

## Install the Neovim plugin

Add this spec to your lazy.nvim plugins:

```lua
{
  "austinphilp/agent-notes.nvim",
  lazy = false,
  opts = {
    -- Listen on a well-known socket so the nvim MCP server can find this nvim.
    socket = true,
  },
}
```

The plugin loads at startup and defines the global `AgentNotes` table, so an agent can call it at any time. Set `mapleader` before lazy.nvim loads plugins, because the keymaps use `<Leader>`.

## Install the Claude Code plugin

1. Add this repository as a plugin marketplace:

   ```sh
   claude plugin marketplace add austinphilp/agent-notes.nvim
   ```

2. Install the plugin:

   ```sh
   claude plugin install agent-notes@agent-notes-nvim
   ```

3. Start Claude Code and ask Claude to show you some code in nvim. Claude starts a background nvim session, sets it up, and gives you a command to attach to it. See [Review sessions](#review-sessions).

The MCP server's tools appear as `mcp__plugin_agent-notes_nvim__<tool>`. If you already have an MCP server named `nvim` that runs the same wrapper, remove it, so Claude does not see two copies of each tool.

## Review sessions

By default the `nvim-review` skill does not use an nvim you already have open. Claude starts a headless nvim with your normal config in the repository it is showing, opens the files, adds the notes and jumps to the first one. Then it gives you one command to attach:

```sh
nvim --remote-ui --server ~/.cache/nvim/session-1234.sock
```

The command opens the session's UI in your terminal. `:detach` (Neovim 0.11 or later) or closing the terminal leaves the session running, and you can attach again with the same command. The first `:detach` after attaching can fail with "no current client" (seen on Neovim 0.12.5); run it again. `:qa` ends the session. Claude stops the session when the review is over, unless you ask to keep it.

Each Claude Code session gets its own nvim, so two agents reviewing at the same time never drive each other's nvim. The launcher is `bin/nvim-session`:

| Command | Effect |
| --- | --- |
| `nvim-session start [dir]` | Starts `nvim --headless --listen` in `dir` (default: the current directory) and waits until it answers and has loaded agent-notes.nvim. Then it prints the attach command. If this agent's session already runs, it prints the command again. |
| `nvim-session stop [--force] [id]` | Ends this agent's session, or session `id`, and removes its files. It refuses while the session has unsaved changes or does not answer, unless you pass `--force`. |
| `nvim-session list` | Shows every session: its id, whether it runs, the number of attached UIs, whether its Claude Code process still runs, when it started and its directory. |

A session belongs to the Claude Code process that started it. Its id is that process's pid, which Claude Code gives Bash commands as `CLAUDE_PID`. The MCP server finds the same process as its parent. The session id does not work as a key, because an MCP server keeps the id it started with after `/clear` gives Bash a new one. The files are `session-<id>.sock`, `.info` and `.log` in `${XDG_CACHE_HOME:-~/.cache}/nvim`.

A session that nobody stops quits on its own once its Claude Code process has exited and no UI has been attached for 30 minutes. Unsaved changes keep it running. Set `NVIM_SESSION_IDLE` to change the time, in seconds. `NVIM_SESSION_TIMEOUT` (default 60 seconds) bounds how long `start` waits for nvim.

## Configure

Call `require("agent-notes").setup(opts)`. lazy.nvim calls it for you with the spec's `opts`.

| Option | Type | Default | Effect |
| --- | --- | --- | --- |
| `socket` | boolean | `false` | Listens on a well-known socket that `bin/nvim-mcp` looks for. |

The socket is for agents that drive an nvim you started yourself; review sessions do not need it. It is off by default because it lets any local process that knows the path drive your nvim. With `socket = true`, the path is `stdpath("cache")/default.sock`. Inside [herdr](https://github.com/herdrdev/herdr), it is `stdpath("cache")/herdr-<workspace>.sock` for the herdr workspace in `$HERDR_WORKSPACE_ID`. The first nvim to start owns the path. Other nvims claim it when they gain focus after the owner exits. Setting `socket = false` later stops the claims. A socket that this nvim already listens on stays open until nvim exits. A session nvim started by `nvim-session` never claims the socket, so it does not take the place of your own nvim.

The plugin keeps its state under `stdpath("state")/agent-notes/`:

- `settings.json` holds the autofloat choice. If it does not exist, the plugin reads `stdpath("state")/claude-notes/settings.json`, where the earlier claude-notes tooling saved it.
- `<id>.jsonl` files are reply channels created by `AgentNotes.channel(id)`.

The highlight groups link to diagnostic colours by default. To change them, define these groups in your colourscheme or config:

| Group | Default link | Used for |
| --- | --- | --- |
| `AgentNoteInfo` | `DiagnosticInfo` | `info` notes |
| `AgentNoteWarn` | `DiagnosticWarn` | `warn` notes |
| `AgentNoteIssue` | `DiagnosticError` | `issue` notes |
| `AgentNoteYou` | `DiagnosticOk` | your replies in a thread |
| `AgentNoteStep` | `Comment` | the step number, such as `3/10` |

## Keys and commands

| Key | `:AgentNotes` action | Effect |
| --- | --- | --- |
| `<Leader>an` | `next` | Shows the next note, wrapping at the end. |
| `<Leader>ap` | `prev` | Shows the previous note, wrapping at the start. |
| `<Leader>al` | `list` | Opens the notes list, a quickfix list of its own. |
| `<Leader>as` | `show` | Toggles the note float for the cursor line. |
| `<Leader>ae` | `enter` | Enters the note float, to scroll it or use its links. |
| `<Leader>ag` | `follow` | Follows a note's link, with a picker when there are several. |
| `<Leader>ar` | `reply` | Opens the chat for the note. Only notes with a channel accept replies. |
| `<Leader>af` | `autofloat` | Toggles whether stepping opens the note float. The choice persists. |
| | `replies` | Prints your replies. |
| | `summary` | Prints one line per note. |
| | `clear` | Removes every note. |
| | `reload` | Re-requires the Lua modules and keeps notes, channels and threads. |

`:AgentNotes` without an action opens the list. In the note float, `<CR>` follows the link under the cursor and `q` closes the float. In the chat, `<C-CR>` or `<C-s>` sends, and `q` or `<Esc>` in Normal mode closes it.

## API

The functions live on the global `AgentNotes` table, which is also `require("agent-notes")`.

### `AgentNotes.add(spec)`

Adds one note and returns its id. Adding a note identical to an existing one returns the existing id. On a bad kind, path, line or link target, `add` raises an error and adds nothing. `spec` fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `file` | yes | Path of the file, absolute or relative to nvim's cwd. The file need not be open. |
| `line` | yes | First line, 1-based. |
| `end_line` | no | Last line. Defaults to `line`. |
| `kind` | no | `info` (default), `warn` or `issue`. |
| `text` | yes | Note text. `\n` starts a new line. `[[path:line]]` and `[[path:line\|label]]` are links. |
| `order` | no | Position in reading order. Notes with equal orders keep call order. Defaults to after the last note. |
| `channel` | no | A channel id or path from `channel()`, so the user can reply. |

A JSON `null` field counts as absent.

### Other functions

| Function | Effect |
| --- | --- |
| `list()` | Returns the notes in reading order as tables with `id`, `order`, `kind`, `file`, `line`, `end_line`, `text`, `links` and `thread`. |
| `summary()` | Prints and returns one line per note: `N. #id [kind] path:lines  first line`, plus its links. |
| `jump(i)` | Shows the `i`-th note in reading order. |
| `next()`, `prev()` | Show the next or previous note, wrapping at either end. |
| `open()` | Opens the notes list. |
| `show()` | Toggles the note float for the cursor line. |
| `enter()` | Enters the note float, opening it for the cursor line first. |
| `follow()` | Follows a link from the focused float, the notes list or the cursor line. |
| `clear([filter])` | Removes notes and returns how many. With no argument it removes all notes. A string removes one file's notes. `{ file = ?, channel = ? }` removes the notes that match. |
| `channel([id])` | Creates a reply channel and prints and returns its path. `id` is a name under `stdpath("state")/agent-notes`, or a path that ends in `.jsonl`. Without `id`, it picks a new unique name. |
| `respond(id, text)` | Adds the agent's answer to note `id`'s thread and notifies the user. |
| `reply()` | Opens the chat for the note in the focused float or on the cursor line. |
| `replies([channel])` | Prints and returns the user's replies in reading order, optionally only those to one channel's notes. |
| `autofloat([on])` | Sets whether stepping opens the note float, or toggles it without an argument. Saves the choice. |
| `setup(opts)` | Applies options. See [Configure](#configure). |

### Reply channels

A channel is a JSONL file. Each reply and each `respond()` call appends one line:

```json
{"type":"reply","note":3,"order":2,"file":"/abs/a.go","line":42,"excerpt":"first line of the note","text":"the message","time":"2026-10-20T15:00:00Z"}
```

`type` is `reply` for the user's messages and `response` for the agent's. An agent can watch the file for `"type":"reply"` lines, for example with `tail -n0 -F <path>`.

## Scripts

The Claude Code plugin runs these from its `bin/` directory:

- `bin/nvim-session` starts, stops and lists review sessions. See [Review sessions](#review-sessions).
- `bin/nvim-mcp` starts `mcp-neovim-server`. `$NVIM_SOCKET_PATH` wins when it is set. Otherwise, from the time this agent starts a session until it stops it, the server drives only that session's nvim. That holds even after the session's nvim exits, so the tools never fall back to your own nvim mid-review. Without a session, it uses the first live socket of the herdr workspace socket and `default.sock`. The server picks the socket again on every tool call, so nvim and the session can start after it. `nvim-mcp --check` prints the socket and fails when no nvim listens there. `nvim-mcp --socket-path` prints it without checking.
- `bin/nvim-focus` switches herdr to the pane that runs that nvim, or to the pane where you attached to the session. If no nvim listens on the socket, it fails like `nvim-mcp --check`. Outside herdr, or when that nvim is not in a pane of this herdr workspace, it prints a note and exits 0.

The scripts look for sockets in `${XDG_CACHE_HOME:-~/.cache}/nvim`, which matches `stdpath("cache")` for the default `NVIM_APPNAME`.

## Develop

Run the headless tests:

```sh
make test
```

`tests/run.sh` runs each `tests/*_spec.lua` file in its own `nvim --clean --headless` with fresh XDG directories. Set `NVIM` to test another nvim binary. The session tests also need `nvim`, `node` and `perl` on `PATH`.

## License

MIT. See [LICENSE](LICENSE).
