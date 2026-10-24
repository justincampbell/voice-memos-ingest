#!/usr/bin/env bash
#
# run.sh — launch the vmchannel binary for the Claude Code channel plugin.
#
# Claude Code starts this (via .mcp.json) when a session is launched with
#   claude --dangerously-load-development-channels plugin:voice-memos@<marketplace>
# It just locates the built `vmchannel` executable and execs it, inheriting
# stdin/stdout (the MCP stdio transport) and stderr (logs).
#
# An *installed* plugin runs from a copy under ~/.claude/plugins/cache/, not
# from this repo, so a repo-relative `.build/` path can't be the primary lookup
# — install the binary to a stable location first (see channel/README.md):
#   make install-channel        # builds and copies to ~/.local/bin/vmchannel
#
# Override the binary with VMCHANNEL_BIN if it lives somewhere else.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"

candidates=(
  "${VMCHANNEL_BIN:-}"
  "${HOME}/.local/bin/vmchannel"
  # Only reachable when running straight out of a checkout (e.g. --plugin-dir).
  "${repo}/.build/release/vmchannel"
  "${repo}/.build/debug/vmchannel"
)

# vmchannel takes no arguments, so none are forwarded. (Don't add `"${@}"`
# back: under `set -u`, macOS's stock bash 3.2 treats an empty `${@}` as an
# unbound variable and dies before exec.)
for bin in "${candidates[@]}"; do
  if [ -n "${bin}" ] && [ -x "${bin}" ]; then
    exec "${bin}"
  fi
done

if command -v vmchannel >/dev/null 2>&1; then
  exec vmchannel
fi

printf 'run.sh: vmchannel binary not found. From the voice-memos-ingest repo, run:\n' >&2
printf '  make install-channel\n' >&2
exit 1
