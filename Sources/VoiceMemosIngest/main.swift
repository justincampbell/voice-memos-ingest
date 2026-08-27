// VoiceMemosIngest — resident menu-bar app entry point.

import AppKit
import VMIngestCore

// launchd agents start with a 256-fd soft limit; exhausting it once soft-locked
// the machine's keyboard (see FDUsage.swift). Raise it before AppKit opens
// anything.
FDUsage.raiseLimit()

let app = NSApplication.shared
// Menu-bar / accessory app: no Dock icon, no main window (LSUIElement-equivalent
// even when run unbundled).
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
