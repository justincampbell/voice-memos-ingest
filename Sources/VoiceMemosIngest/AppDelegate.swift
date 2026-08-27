// AppDelegate.swift — the resident menu-bar shell.
//
// Shows an NSStatusItem whose menu reports watch state / total emitted / last
// memo / last error, watches the Recordings dir via FSEvents (debounced), runs
// the VMIngestCore pipeline on changes, posts a notification per processed memo,
// and keeps status.json current for the CLI.
//
// Threading rules, learned the hard way (see CLAUDE.md's architecture notes): a
// main-thread stall while the status menu is tracking holds the input grab and
// freezes the keyboard system-wide. So the main actor never touches the
// filesystem, and the status menu is created exactly once — its contents are
// refreshed lazily in menuNeedsUpdate(_:) from cached state, and
// statusItem.menu is never reassigned while it could be open.

import AppKit
import Foundation
import UserNotifications
import VMIngestCore
import VMIngestMCP

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var watcher: FSWatcher?
    private let config: Config
    private var status = Status()
    private var isRunning = false
    private var rerunRequested = false

    /// Cached verdict of the last Full Disk Access probe. Only ever read on the
    /// main actor; refreshed asynchronously by refreshDiskAccess(). FDA has no
    /// request API, so we probe for it and, when missing, guide the user to the
    /// Settings pane.
    private var hasDiskAccess = true

    /// Bumped every time access is confirmed — by a successful probe, or by a
    /// pipeline run that actually read Apple's database. A probe that started
    /// before the latest confirmation must not paint its stale negative over it.
    private var accessConfirmations = 0

    /// Whether the status menu is currently open (tracking). While it is, the
    /// app holds the window server's input grab, so the fd watchdog must not
    /// restart the process — that's the keyboard-freeze hazard itself.
    private var menuIsOpen = false
    private var restartPending = false

    /// Serial queue for status-file writes: keeps the I/O off the main actor
    /// while preserving write order.
    private let statusIOQueue = DispatchQueue(label: "me.justincampbell.voice-memos-ingest.status-io")

    /// Live edge for MCP consumers; fed every newly emitted record.
    private let eventHub = TranscriptEventHub()
    private var mcpHost: MCPHTTPHost?

    private let iso = ISO8601DateFormatter()

    override init() {
        // Load config up front; fall back to defaults on error.
        self.config = (try? Config.load()) ?? Config.defaults()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"

        // The one and only menu. Contents are filled in menuNeedsUpdate(_:)
        // right before each open; the object itself is never replaced.
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Notifications require a bundle identity; skip gracefully when run
        // unbundled (e.g. `swift run`) — they light up once packaged in step 10.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        status.running = true
        status.watchingSince = iso.string(from: Date())
        saveStatus()
        refreshDiskAccess(retryDelays: RecordingsAccessProbe.startupRetryDelays)

        watcher = FSWatcher(path: config.recordingsDir) { [weak self] in
            Task { @MainActor in self?.runPipeline(reason: "fs-event") }
        }
        watcher?.start()

        // Host the MCP server so local agents can query transcripts and
        // subscribe to new ones. Loopback-only; failures (e.g. port in use)
        // are non-fatal to the watcher.
        if config.mcpEnabled {
            let host = MCPHTTPHost(config: config, hub: eventHub)
            mcpHost = host
            Task {
                do { try await host.start() }
                catch { await MainActor.run { self.status.lastError = "mcp: \(error)"; self.saveStatus() } }
            }
        }

        // Count what's already been emitted (off the main thread — the file can
        // be large), then catch up on anything that arrived while we weren't
        // running. Sequenced so the catch-up run's increments land on top of
        // the counted baseline rather than racing it.
        let transcriptsPath = config.transcriptsPath
        Task { [weak self] in
            let count = await BlockingWork.value(within: .seconds(5), fallback: 0) {
                Self.countLines(atPath: transcriptsPath)
            }
            guard let self else { return }
            self.status.totalEmitted = count
            self.saveStatus()
            self.runPipeline(reason: "launch")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        if let host = mcpHost { Task { await host.stop() } }
        status.running = false
        // Synchronous on purpose: an async write queued here would be killed
        // with the process. Runs after any pending writes on the serial queue.
        let snapshot = status
        let path = config.statusPath
        statusIOQueue.sync { try? snapshot.save(path: path) }
    }

    // MARK: - Pipeline

    private func runPipeline(reason: String) {
        // Serialize runs. If a trigger arrives mid-run, remember it and run once
        // more afterwards so a memo that synced during a run isn't left until the
        // next FS event.
        guard !isRunning else { rerunRequested = true; return }
        isRunning = true
        let config = self.config
        Task { @MainActor in
            do {
                let result = try await Pipeline.runOnce(config: config)
                self.handleResult(result)
            } catch {
                self.handleError(error)
            }
            self.isRunning = false
            if self.rerunRequested {
                self.rerunRequested = false
                self.runPipeline(reason: "coalesced")
            }
        }
    }

    private func handleResult(_ result: RunResult) {
        status.lastRunAt = iso.string(from: Date())
        status.lastError = result.errors.first
        checkFDUsage()
        for record in result.emittedRecords {
            status.totalEmitted += 1
            status.lastMemoTitle = record.title
            status.lastMemoAt = record.recordedAt
            notify(record)
        }
        // Wake MCP long-pollers and push to subscribed sessions.
        if !result.emittedRecords.isEmpty {
            let records = result.emittedRecords
            Task { await eventHub.publish(records) }
        }
        saveStatus()
        // The run read Apple's database, so access is not in question — no
        // probe needed, and this outranks any probe still retrying.
        confirmDiskAccess()
    }

    private func handleError(_ error: Error) {
        status.lastRunAt = iso.string(from: Date())
        status.lastError = "\(error)"
        checkFDUsage()
        saveStatus()
        refreshDiskAccess()
    }

    // MARK: - FD watchdog

    /// Update the fd-count canary after each pipeline run and act on it. A slow
    /// fd leak once reached EMFILE here, at which point *AppKit itself* failed
    /// mid-menu-open and wedged the window server's keyboard grab system-wide.
    /// Restarting early (via launchd KeepAlive) makes that state unreachable —
    /// but only ever with the menu closed; see restartIfSafe().
    private func checkFDUsage() {
        Task { [weak self] in
            let count = await BlockingWork.value(within: .seconds(2), fallback: -1) {
                FDUsage.count() ?? -1
            }
            guard let self, count >= 0 else { return }
            self.status.openFDs = count
            switch FDUsage.verdict(count: count) {
            case .ok:
                break
            case .warn:
                if self.status.lastError == nil {
                    self.status.lastError = "fd leak? \(count) descriptors open"
                }
            case .restart:
                self.restartPending = true
            }
            self.saveStatus()
            self.restartIfSafe()
        }
    }

    /// Exit with a non-zero status so launchd's KeepAlive(SuccessfulExit:false)
    /// respawns a clean process — deferred while the menu is open, because
    /// dying mid-menu-tracking is exactly the input-grab wedge we're avoiding.
    /// menuDidClose(_:) retries a deferred restart.
    private func restartIfSafe() {
        guard restartPending, !menuIsOpen else { return }
        watcher?.stop()
        status.running = false
        status.lastError = "fd watchdog: \(status.openFDs ?? -1) descriptors open; restarting"
        let snapshot = status
        let path = config.statusPath
        statusIOQueue.sync { try? snapshot.save(path: path) }
        exit(70)
    }

    // MARK: - Notifications

    private func notify(_ record: TranscriptRecord) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "New voice memo transcribed"
        content.body = record.text.count > 120 ? String(record.text.prefix(117)) + "…" : record.text
        let request = UNNotificationRequest(identifier: record.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Status file helpers

    private func saveStatus() {
        let snapshot = status
        let path = config.statusPath
        statusIOQueue.async { try? snapshot.save(path: path) }
    }

    private nonisolated static func countLines(atPath path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    // MARK: - Menu

    /// Fills the (single, long-lived) status menu from cached state only — no
    /// filesystem access, nothing that can block: this runs on the main thread
    /// with the menu about to open.
    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(header("Voice Memos Ingest"))
        menu.addItem(info(status.running ? "● watching" : "○ idle"))
        if !hasDiskAccess {
            menu.addItem(info("⚠︎ No Full Disk Access — can't read recordings"))
            let grant = NSMenuItem(title: "Grant Full Disk Access…", action: #selector(grantFullDiskAccess), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        if let since = status.watchingSince { menu.addItem(info("since \(short(since))")) }
        menu.addItem(.separator())
        menu.addItem(info("total emitted: \(status.totalEmitted)"))
        if let t = status.lastMemoTitle { menu.addItem(info("last: \(t)")) }
        if let e = status.lastError { menu.addItem(info("⚠︎ \(e.prefix(60))")) }
        menu.addItem(.separator())

        let runItem = NSMenuItem(title: "Run now", action: #selector(runNow), keyEquivalent: "r")
        runItem.target = self
        menu.addItem(runItem)

        let openItem = NSMenuItem(title: "Open transcripts file", action: #selector(openTranscripts), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func header(_ s: String) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func info(_ s: String) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func short(_ iso: String) -> String {
        // Trim to "MM-dd HH:mm" for compactness.
        guard iso.count >= 16 else { return iso }
        let start = iso.index(iso.startIndex, offsetBy: 5)
        let end = iso.index(iso.startIndex, offsetBy: 16)
        return String(iso[start..<end]).replacingOccurrences(of: "T", with: " ")
    }

    // MARK: - Full Disk Access

    /// Kick an FDA probe off the main thread and cache the verdict. The probe
    /// lists the iCloud group container, which can hang outright when TCC
    /// denies access or the sync daemon is wedged — RecordingsAccessProbe
    /// bounds it with a deadline, and a timeout reads as "no access".
    ///
    /// Which is why nothing here trusts a single negative: at launch the cold
    /// container regularly overran the deadline, and the app then wore 🎙️⚠️
    /// with FDA fully granted until the user happened to open the menu (which
    /// re-probes) and clear it — observed 2026-08-22. Callers pass a retry
    /// schedule instead; launch uses the long one.
    private func refreshDiskAccess(
        retryDelays: [Duration] = RecordingsAccessProbe.confirmRetryDelays
    ) {
        let dir = config.recordingsDir
        let confirmations = accessConfirmations
        Task { [weak self] in
            let ok = await RecordingsAccessProbe.probeUntilGranted(
                recordingsDir: dir, retryDelays: retryDelays
            )
            guard let self else { return }
            if ok { self.confirmDiskAccess(); return }
            // Access was confirmed elsewhere while this probe was still
            // retrying, so this verdict is stale — drop it.
            guard self.accessConfirmations == confirmations else { return }
            self.hasDiskAccess = false
            self.statusItem.button?.title = "🎙️⚠️"
        }
    }

    private func confirmDiskAccess() {
        accessConfirmations += 1
        hasDiskAccess = true
        statusItem.button?.title = "🎙️"
    }

    /// As close to "requesting" FDA as macOS allows: deep-link straight to the
    /// Full Disk Access pane and reveal our own binary in Finder so the user can
    /// drag it into the list. They must still add and toggle it themselves, and
    /// may need to relaunch the app afterward for the grant to take effect.
    @objc private func grantFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        // Reveal the thing to drag into the FDA list: the .app bundle when
        // running bundled (so the grant attaches to the signed identity), or the
        // bare executable when unbundled (e.g. under `swift run`).
        let reveal: URL? = Bundle.main.bundleIdentifier != nil
            ? Bundle.main.bundleURL
            : (Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first)
                .map { URL(fileURLWithPath: $0) }
        if let reveal {
            NSWorkspace.shared.activateFileViewerSelecting([reveal])
        }
    }

    @objc private func runNow() { runPipeline(reason: "manual") }

    @objc private func openTranscripts() {
        NSWorkspace.shared.open(URL(fileURLWithPath: config.transcriptsPath))
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Called by AppKit right before the menu opens. Populate from cached
    /// state (fast, non-blocking) and kick a fresh async probe so a stale
    /// verdict corrects itself by the next open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
        refreshDiskAccess()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        restartIfSafe()
    }
}
