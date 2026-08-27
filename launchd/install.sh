#!/usr/bin/env bash
# Install VoiceMemosIngest as a per-user LaunchAgent that runs at login.
#
# This is a LaunchAgent, NOT a LaunchDaemon, on purpose: VoiceMemosIngest is a
# menu-bar app (NSStatusItem) and must run inside the user's GUI (Aqua) session.
# A daemon runs before/without login and cannot host a menu-bar item.
#
# Nothing here is personal beyond $HOME, so it is safe to check in.
#
# After running this once, grant Full Disk Access to the installed app (printed
# at the end) so it can read the Voice Memos container. Because the app is signed
# with a stable identity, that grant persists across rebuilds.
set -euo pipefail

LABEL="me.justincampbell.voice-memos-ingest"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${HOME}/.local/share/voice-memos-ingest"   # logs + pipeline data
APP_SRC="${REPO_ROOT}/.build/VoiceMemosIngest.app"   # freshly built bundle
APP="${HOME}/Applications/VoiceMemosIngest.app"      # installed bundle
BIN="${APP}/Contents/MacOS/VoiceMemosIngest"         # what launchd execs
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

# Build + code-sign the .app bundle (packaging/package.sh handles the cert).
"${REPO_ROOT}/packaging/package.sh"

# Install into ~/Applications.
mkdir -p "${HOME}/Applications" "${DATA_DIR}"
rm -rf "${APP}"
cp -R "${APP_SRC}" "${APP}"

mkdir -p "${HOME}/Library/LaunchAgents"
cat > "${PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restart on a crash, but NOT after a clean Quit from the menu (that
         exits 0, so SuccessfulExit=false leaves it stopped). -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <!-- GUI session only; this is what makes it an agent, not a daemon. -->
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${DATA_DIR}/agent.out.log</string>
    <key>StandardErrorPath</key>
    <string>${DATA_DIR}/agent.err.log</string>
</dict>
</plist>
PLISTEOF

# (Re)load into the current GUI domain.
#
# `bootout` is ASYNCHRONOUS: it returns before the old job is actually gone, so
# bootstrapping straight after it fails with "Bootstrap failed: 5: Input/output
# error" whenever a previous instance was loaded. Wait for the label to leave
# the domain (bounded, so a wedged job can't hang the install) before
# bootstrapping.
DOMAIN="gui/$(id -u)"
if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    echo "Unloading existing ${LABEL}…"
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    for _ in $(seq 1 50); do
        launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || break
        sleep 0.2
    done
fi

launchctl bootstrap "${DOMAIN}" "${PLIST}"
launchctl enable "${DOMAIN}/${LABEL}"
launchctl kickstart -k "${DOMAIN}/${LABEL}"

echo
echo "Installed and loaded: ${LABEL}"
echo "App: ${APP}"
echo
echo "NEXT — grant Full Disk Access to the app, or it will read an empty"
echo "Recordings dir. Easiest: click the menu-bar 🎙️⚠️ → \"Grant Full Disk"
echo "Access…\" (it reveals the app for you). Or manually:"
echo "  System Settings → Privacy & Security → Full Disk Access → +"
echo "  (press ⌘⇧G in the file picker and paste: ${APP} )"
echo "Then relaunch: launchctl kickstart -k gui/\$(id -u)/${LABEL}"
