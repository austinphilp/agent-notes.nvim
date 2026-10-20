#!/usr/bin/env bash
# Runs each tests/*_spec.lua (or each spec given) in its own headless nvim with
# this repo on the runtimepath and fresh XDG directories, so no user config or
# state is touched.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
nvim=${NVIM:-nvim}
failed=0

if [[ $# -gt 0 ]]; then specs=("$@"); else specs=("$root"/tests/*_spec.lua); fi

# A spec that errors outside a test would otherwise leave nvim running.
run='lua local ok, err = pcall(dofile, vim.env.NVIM_TEST_SPEC)
if not ok then io.stdout:write("FAIL ", vim.env.NVIM_TEST_SPEC, ": ", tostring(err), "\n") vim.cmd "cquit 1" end'

for spec in "${specs[@]}"; do
  # macOS caps socket paths near 104 bytes, so keep the cache dir short.
  tmp=$(mktemp -d "${TMPDIR:-/tmp}"/agent-notes.XXXXXX)
  if ! XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" \
    XDG_CACHE_HOME="$tmp/cache" HERDR_WORKSPACE_ID="" NVIM_TEST_TMP="$tmp" NVIM_TEST_SPEC="$spec" \
    NVIM_TEST_ROOT="$root" "$nvim" --clean --headless -n \
    --cmd "lua vim.opt.rtp:prepend(vim.env.NVIM_TEST_ROOT)" -c "$run"; then
    failed=1
  fi
  rm -rf "$tmp"
done

exit "$failed"
