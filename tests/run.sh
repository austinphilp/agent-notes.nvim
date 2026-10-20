#!/usr/bin/env bash
# Runs each tests/*_spec.lua in its own headless nvim with this repo on the
# runtimepath and fresh XDG directories, so no user config or state is touched.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
nvim=${NVIM:-nvim}
failed=0

for spec in "${@:-$root/tests/*_spec.lua}"; do
  for file in $spec; do
    # macOS caps socket paths near 104 bytes, so keep the cache dir short.
    tmp=$(mktemp -d "${TMPDIR:-/tmp}"/agent-notes.XXXXXX)
    if ! XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" \
      XDG_CACHE_HOME="$tmp/cache" HERDR_WORKSPACE_ID="" NVIM_TEST_TMP="$tmp" \
      "$nvim" --clean --headless -n --cmd "set rtp^=$root" -c "luafile $file"; then
      failed=1
    fi
    rm -rf "$tmp"
  done
done

exit "$failed"
