// Preloaded into mcp-neovim-server by nvim-mcp (node --import, via npx -c).
// The server reads process.env.NVIM_SOCKET_PATH on every tool call. Answer
// with the first candidate socket (NVIM_MCP_SOCKETS, colon-separated, in
// priority order) that has a live nvim, so the choice follows nvim starting,
// exiting, or moving after the server has launched.
import { spawnSync } from "node:child_process";

const candidates = (process.env.NVIM_MCP_SOCKETS ?? "").split(":").filter(Boolean);

const isLive = (path) =>
  spawnSync("nvim", ["--server", path, "--remote-expr", "1"], { stdio: "ignore", timeout: 2000 }).status === 0;

if (candidates.length > 0) {
  process.env = new Proxy(process.env, {
    get(target, key) {
      if (key !== "NVIM_SOCKET_PATH") return Reflect.get(target, key);
      return candidates.find(isLive) ?? candidates.at(-1);
    },
  });
}
