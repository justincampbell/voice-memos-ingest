#!/usr/bin/env bash
# Build and code-sign VoiceMemosIngest.app.
#
# Produces a proper .app bundle — a menu-bar/agent app (LSUIElement, no Dock
# icon) — signed with a STABLE identity, so TCC grants (Full Disk Access,
# notifications, Automation) survive rebuilds instead of resetting each time the
# binary's code hash changes. Bundling also gives it a CFBundleIdentifier, which
# is what turns notifications on in AppDelegate.
#
# Signing identity: override with SIGN_IDENTITY=…, or create the free default
# self-signed cert once (see the error message below for the exact steps).
#
# Output: .build/VoiceMemosIngest.app  (path echoed at the end)
set -euo pipefail

BUNDLE_ID="me.justincampbell.voice-memos-ingest"
SIGN_IDENTITY="${SIGN_IDENTITY:-VoiceMemosIngest Signing}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${REPO_ROOT}/.build/VoiceMemosIngest.app"

# Fail early (before building) if the signing identity is missing. No -v here:
# a self-signed cert is untrusted (CSSMERR_TP_NOT_TRUSTED) so the "valid
# identities only" filter hides it, but codesign still signs with it and its
# designated requirement (bundle id + leaf cert) is stable across rebuilds —
# which is all TCC needs for the Full Disk Access grant to persist.
if ! security find-identity -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
    cat >&2 <<MSG
error: code-signing identity "${SIGN_IDENTITY}" not found.

Create a free self-signed one — it persists TCC grants across rebuilds:
  1. open -a "Keychain Access"
  2. Menu: Keychain Access → Certificate Assistant → Create a Certificate…
  3. Name:            ${SIGN_IDENTITY}
     Identity Type:   Self-Signed Root
     Certificate Type: Code Signing
  4. Create → Continue → Done

Then re-run this script. (Or point SIGN_IDENTITY=… at a different cert.)
MSG
    exit 1
fi

echo "Building release binary…"
( cd "${REPO_ROOT}" && swift build -c release --product VoiceMemosIngest )

echo "Assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp "${REPO_ROOT}/.build/release/VoiceMemosIngest" "${APP}/Contents/MacOS/VoiceMemosIngest"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>VoiceMemosIngest</string>
    <key>CFBundleDisplayName</key>           <string>Voice Memos Ingest</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>            <string>VoiceMemosIngest</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>26.0</string>
    <!-- Agent app: menu-bar only, no Dock icon or app switcher entry. -->
    <key>LSUIElement</key>                   <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "Signing with \"${SIGN_IDENTITY}\"…"
# --identifier pins the signing identifier to the bundle id so the designated
# requirement (what TCC matches on) is stable across rebuilds.
codesign --force --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP}"
codesign --verify --verbose "${APP}"

echo
echo "Built and signed: ${APP}"
