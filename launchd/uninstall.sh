#!/usr/bin/env bash
# Unload and remove the VoiceMemosIngest LaunchAgent.
# Leaves the installed binary and data (transcripts.jsonl, seen.json) in place.
set -euo pipefail

LABEL="me.justincampbell.voice-memos-ingest"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
rm -f "${PLIST}"
echo "Unloaded and removed ${LABEL}."
echo "(App at ~/Applications/VoiceMemosIngest.app and data left in place.)"
