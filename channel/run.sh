#!/usr/bin/env bash
#
# run.sh — launch the vmchannel binary for the Claude Code channel plugin.
#
# Claude Code starts this (via .mcp.json) when a session is launched with
#   claude --channels plugin:voice-memos@<marketplace>
# It just locates the built `vmchannel` executable and execs it, inheriting
# stdin/stdout (the MCP stdio transport) and stderr (logs). The binary is a
# build artifact and is NOT committed, so build it first (see channel/README.md):
#   swift build -c release --product vmchannel
#
# Override the binary with VMCHANNEL_BIN if it lives somewhere else.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"

candidates=(
  "${VMCHANNEL_BIN:-}"
  "${repo}/.build/release/vmchannel"
  "${repo}/.build/debug/vmchannel"
)

for bin in "${candidates[@]}"; do
  if [ -n "${bin}" ] && [ -x "${bin}" ]; then
    exec "${bin}" "${@}"
  fi
done

if command -v vmchannel >/dev/null 2>&1; then
  exec vmchannel "${@}"
fi

printf 'run.sh: vmchannel binary not found. Build it first:\n' >&2
printf '  (cd %s && swift build -c release --product vmchannel)\n' "${repo}" >&2
exit 1
