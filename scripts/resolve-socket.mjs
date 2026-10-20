// Preloaded into mcp-neovim-server by nvim-mcp (node --import, via npx -c).
// The server reads process.env.NVIM_SOCKET_PATH on every tool call. While this
// agent's session file (NVIM_MCP_SESSION_INFO) exists, answer with its session
// socket (NVIM_MCP_SESSION_SOCKET). Otherwise answer with the first candidate
// socket (NVIM_MCP_SOCKETS, colon-separated, in priority order) that has a live
// nvim, so the choice follows sessions and nvims starting, exiting, or moving
// after the server has launched.
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";

const candidates = (process.env.NVIM_MCP_SOCKETS ?? "").split(":").filter(Boolean);
const sessionSocket = process.env.NVIM_MCP_SESSION_SOCKET;
const sessionInfo = process.env.NVIM_MCP_SESSION_INFO;

const isLive = (path) =>
  spawnSync("nvim", ["--server", path, "--remote-expr", "1"], { stdio: "ignore", timeout: 2000 }).status === 0;

const resolve = () => {
  if (sessionSocket && sessionInfo && existsSync(sessionInfo)) return sessionSocket;
  return candidates.find(isLive) ?? candidates.at(-1);
};

if (candidates.length > 0) {
  process.env = new Proxy(process.env, {
    get(target, key) {
      if (key !== "NVIM_SOCKET_PATH") return Reflect.get(target, key);
      return resolve();
    },
  });
}
