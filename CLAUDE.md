# voice-memos-ingest

A macOS tool that watches Apple Voice Memos and continuously appends their
transcripts to a machine-readable file (and optionally an Apple Note), so other
automations can pick up new voice notes without any LLM in the loop.

**Intended end-to-end flow:**
Record on iPhone/Apple Watch → recording + transcript sync to the Mac via iCloud
→ this tool extracts the transcript and appends it to an immutable, append-only
file → some downstream consumer (a script, an agent, etc.) reads new entries and
acts on them.

This ships as an all-Swift Swift Package: a resident **menu-bar app**
(`VoiceMemosIngest`) that watches the Recordings dir via FSEvents and runs the
pipeline, plus a **CLI** (`vmingest`) for headless/scripted use and inspection.
All logic lives in the `VMIngestCore` library. No LLM, no cloud service, and no
*outbound* network at runtime — the one socket is the app's optional
loopback-only MCP server for local agents.

## Platform requirements

- macOS 26 (Tahoe) or later. Verified on 26.2, Apple Silicon.
- Swift 6.x toolchain. Build the whole project with `swift build` (it is a
  Swift Package; SQLite is linked via `linkerSettings`).
- **Full Disk Access (TCC)** for whatever process reads the Voice Memos
  container (see below). Without it, the recordings directory appears empty and
  reads fail with "Operation not permitted" — and that error is easy to hide by
  accidentally redirecting stderr to `/dev/null`, so never do that while probing.

## How Apple Voice Memos stores data (the key research)

Everything lives in one iCloud-synced directory:

```
~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/
├── CloudRecordings.db          # Core Data SQLite index (one row per memo)
├── <YYYYMMDD HHMMSS>-<HEX>.m4a # the audio (synced from iPhone/Watch)
└── <...>-track0.waveform       # waveform sidecars (ignore)
```

### The index database

`CloudRecordings.db`, table `ZCLOUDRECORDING`, one row per recording. Useful
columns:

| Column         | Meaning                                                        |
|----------------|----------------------------------------------------------------|
| `ZUNIQUEID`    | stable UUID (also embedded in the `.m4a` as `voice-memo-uuid`)  |
| `ZDATE`        | recorded time, **Core Data epoch** = unix seconds − 978307200   |
| `ZDURATION`    | duration in seconds (float)                                     |
| `ZCUSTOMLABEL` | title shown in the app                                          |
| `ZPATH`        | filename of the `.m4a` within the Recordings dir               |
| `ZFOLDER`      | FK into `ZFOLDER`                                               |

Convert `ZDATE` to a unix timestamp by adding `978307200` (seconds between the
2001 Core Data epoch and the 1970 unix epoch).

The legacy `ZRECORDING` table is empty on modern macOS — use `ZCLOUDRECORDING`.

Read the DB **read-only**, and **copying is mandatory, not optional**: the live
data lives in the multi-MB `-wal` sidecar, and opening with an immutable URI
(`file:...?immutable=1`) ignores the WAL and returns **0 rows**. So always copy
`CloudRecordings.db` *plus* `-wal` and `-shm` to a temp dir and query the copy
(`RecordingsReader` does this and cleans up after itself). This also guarantees
we never lock or touch the app's database.

**Copy with plain byte reads, never `FileManager.copyItem`/clonefile.** APFS
clone fires an `ItemCloned` FSEvent **on the source files** — so a
`copyItem`-based snapshot re-triggers our own FSEvents watcher and locks the
pipeline into a permanent ~2s self-triggering loop (verified live with an
independent FSEvents listener: flags `0x410000` = `ItemIsFile|ItemCloned` for
exactly db/-wal/-shm, every cycle, on an otherwise-static dir). That loop ran
the pipeline ~30k×/day for days and amplified a slow fd leak into EMFILE.
`RecordingsReader.copyBytes` (read + write, no clone, no FS events) is the
sanctioned copy.

### Where the transcript actually lives — `tsrp`

**The transcript is NOT in the database and NOT a separate file.** Apple embeds
its own on-device transcript *inside each `.m4a`* in a custom MP4 atom named
`tsrp`. The payload is JSON of the form:

```json
{"attributedString": {"attributeTable": [ ... ], "runs": ["word ", 0, "next ", 1, ...]},
 "locale": [ ... ]}
```

**`attributedString` has two shapes depending on JSON key order**, and the
extractor must handle both:

- dict shape: `{"attributeTable": [...], "runs": ["word ", 0, "next ", 1, ...]}`
- bare-list shape: `["word ", {attr}, "next ", {attr}, ...]`

In both, **the plain transcript = concatenation of the string elements** (of
`runs` for the dict shape, of the list itself for the bare-list shape). The naive
"first `{` after `tsrp`, decode `runs`" parser breaks on the bare-list shape.

Robust extraction (key order varies, so do not rely on byte offsets): find the
`tsrp` bytes, take the first `{` after it, slice out the brace-balanced JSON
object (tracking string/escape state so a `}` inside a word doesn't truncate
it), JSON-decode, then read `attributedString` handling both shapes. See
`TsrpExtractor`.

**Critical caveat:** the `tsrp` atom only exists once the memo has been
transcribed *somewhere* — it is not generated in the background on this Mac just
by syncing. Two ways it shows up: (a) the memo was opened in the Voice Memos app
on this Mac, or (b) **the recording device (iPhone/Watch) transcribed it and the
`tsrp` synced in with the audio** — confirmed in testing: a memo recorded on
iPhone arrived on the Mac already carrying its `tsrp` (`source: apple`, no local
transcription needed). But a memo recorded and never transcribed anywhere has
audio and no `tsrp`, so a "record and walk away" pipeline still cannot rely on
`tsrp` alone — hence the fallback below.

### Generating transcripts ourselves (the fallback)

macOS 26 ships the `Speech` framework's `SpeechAnalyzer` / `SpeechTranscriber`
API — the same on-device engine Voice Memos uses. We can transcribe any synced
`.m4a` directly, with no app interaction and (in practice) no permission prompt.

This engine is wrapped in-process by `Transcriber` in `VMIngestCore` (no
subprocess, no shelling out). For debugging, `vmingest transcribe <audio-file>`
prints the plain-text transcript to stdout. (The original standalone
`transcribe.swift` has been absorbed into the package.)

### Apple `tsrp` vs. our `SpeechTranscriber` — measured

On a sample of already-transcribed memos the two outputs were 3/5 identical and
2/5 only trivially different (Apple captured slightly more trailing/incomplete
speech and one extra comma; ours had cleaner sentence boundaries). They are the
same engine, so quality is effectively equal. The practical strategy (see
`TranscriptPolicy`): **prefer Apple's embedded `tsrp` when present, fall back to
the in-process transcriber otherwise.** With `alwaysDoubleTranscribe` set, both
are computed and recorded (`apple_text` / `our_text`) for ongoing comparison.

## Output contract

Two layers, with distinct roles:

1. **Canonical append-only file** (e.g. `transcripts.jsonl`) — the machine source
   of truth. One self-contained JSON object per line. Append only; never rewrite
   existing lines. Because it is append-only, a consumer can track progress with
   a simple **byte offset** (or line count) stored in its own cursor file: read
   from the saved offset to EOF, process the new lines, save the new offset.
   Suggested fields per record:
   `id`, `recorded_at` (ISO 8601), `duration`, `title`, `source`
   (`apple` | `speechtranscriber`), `text`, and — when both are computed —
   `apple_text` / `our_text`, plus `transcribed_at`.

2. **Apple Note mirror** (optional, human-facing) — each new transcript appended
   to a dedicated note for easy reading. Treat the Note as a convenience mirror,
   not the source of truth — it is mutable and has no clean cursor.

   **Writing to an existing note — use Shortcuts, not AppleScript `set body`.**
   AppleScript `set body of note` re-renders the note's HTML and **destroys
   checklists, tables, and attachments** — forbidden for appending to a real
   note. The sanctioned path is the Shortcuts **"Append to Note"** action, driven
   by `router/append-note.sh` (marshals `{folder,title,text}` JSON to a Shortcut
   via `shortcuts run`). This is also TCC-safe: the Notes Automation grant
   attaches to Apple's signed Shortcuts runtime, not to our unbundled binary. The
   Shortcut must be created once by hand — see `router/shortcut.md`. **Status:
   `router/` is standalone; the Swift pipeline still calls `AppleNoteMirror`
   (AppleScript) and is not yet wired to the Shortcuts path.** AppleScript should
   stay read-only from here on.

The **producer** tracks which memos it has already emitted (a separate state file
of seen `ZUNIQUEID`s, or a high-water mark on `ZDATE`/`Z_PK`) so it never
re-emits. Keep this separate from any **consumer** cursor.

## Architecture & scheduling

### Targets

One Swift Package, four targets plus two script directories:

- **`VMIngestCore`** — everything with logic in it and no UI: `RecordingsReader`
  (DB), `TsrpExtractor`, `Transcriber`, `TranscriptPolicy`, `ProducerState`,
  `JSONLWriter`, `AppleNoteMirror`, `Status`, `FDUsage`, plus `TranscriptStore`
  (read-only queries over the canonical JSONL) and `TranscriptEventHub`
  (in-process fan-out of newly emitted records). Depends on nothing but
  Foundation/Speech.
- **`VMIngestMCP`** — the MCP surface: `TranscriptToolbox` (behaviour),
  `MCPServerProvider` (SDK wiring), `MCPHTTPHost` (NIO). A library, not part of
  the app, so tests can import it — see the MCP section for why that layering is
  load-bearing.
- **`VoiceMemosIngest`** — the menu-bar app: FSEvents watcher → pipeline →
  notifications, keeps `status.json` current, hosts the MCP server. Executable,
  therefore un-importable and effectively untestable: keep it thin.
- **`vmingest`** — CLI for headless runs and inspection.
- **`packaging/`, `launchd/`** — build+sign the `.app`, install the LaunchAgent.
- **`router/`** — standalone Shortcuts-based Apple Note appender.

The resident `VoiceMemosIngest` menu-bar app is the primary runtime: it watches
the Recordings dir with an FSEvents stream (debounced ~2s), runs
`Pipeline.runOnce` on each change, and keeps `status.json` current. Overlapping
triggers are serialized; an event arriving mid-run schedules exactly one
follow-up so nothing is dropped. The CLI's `run-once` does the same pipeline
headlessly for scripting.

Note the debounce is applied twice — a 2s FSEvents latency *and* a 2s
`asyncAfter` in `FSWatcher` — so the worst-case lag from sync to emit is ~4s,
not ~2s.

### Packaging & autostart (both shipped)

- `packaging/package.sh` builds the release binary and assembles a real `.app`
  (`LSUIElement` ⇒ menu-bar only, no Dock icon; a `CFBundleIdentifier`, which is
  what turns notifications on at all), then **code-signs it**.
- **Signing is what makes Full Disk Access survive rebuilds** — the key finding.
  TCC keys its grant to the code signature, so an unsigned rebuild resets FDA
  every time. A free **self-signed** cert is enough: `codesign --identifier`
  pins the signing identifier to the bundle id, so the designated requirement
  (`identifier "…" and certificate leaf = H"…"`) is stable across rebuilds and
  the grant sticks. No Apple Developer account, no `sudo`, no trust step —
  Gatekeeper doesn't gate a locally-built LaunchAgent.
  - Gotcha: `security find-identity -v` **hides** a self-signed cert (it's
    `CSSMERR_TP_NOT_TRUSTED`, and `-v` means "valid only"), but `codesign` signs
    with it happily. Don't use `-v` to check for the identity.
- `launchd/install.sh` installs to `~/Applications` and loads a per-user
  **LaunchAgent** (`~/Library/LaunchAgents/me.justincampbell.voice-memos-ingest.plist`):
  `RunAtLoad`, `KeepAlive{SuccessfulExit:false}`, `ProcessType=Interactive`, and
  `LimitLoadToSessionType=Aqua`. It must be an **agent, not a daemon** — a
  daemon runs in a non-GUI context where an `NSStatusItem` can't exist. Agents
  load at **login**, not at boot. `launchd/uninstall.sh` removes it.
  - Gotcha: `launchctl bootout` is async, so `bootout` immediately followed by
    `bootstrap` fails with `Bootstrap failed: 5: Input/output error`. Sleep
    ~1s between them, or just use `launchctl kickstart -k` to restart in place.
  - Gotcha: `launchctl list` showing PID `-` with last exit `0` means the agent
    is loaded but **down and staying down** — `KeepAlive{SuccessfulExit:false}`
    does not respawn a clean exit, which is exactly what menu → Quit produces.
- **Two instances can run at once, and they corrupt the output.** macOS's
  login-restore (runningboardd/LaunchServices) relaunches the app as its *own*
  launchd job labelled `application.<bundle-id>.<n>.<n>`, unrelated to the
  `me.justincampbell.voice-memos-ingest` agent job — and `install.sh`'s
  `bootout` only touches the agent's. Installing on top of a restored copy
  therefore leaves two live processes sharing `seen.json` and
  `transcripts.jsonl`: both load the seen set before either saves it, both
  transcribe, both append — a **duplicate line in the append-only file** (hit for
  real 2026-08-22, one memo of three in the window; it's a per-memo coin flip).
  The loser of the race for port 7777 also fails its MCP bind *silently*, since
  `handleResult` overwrites `status.lastError` with `result.errors.first`.
  Nothing guards against this yet. Detect with `ps -Ao pid,lstart,command | grep
  VoiceMemosIngest` and `lsof -nP -iTCP:7777 -sTCP:LISTEN` — not `launchctl
  list`, where the two jobs sit under unrelated labels. Kill the stray, then
  `launchctl kickstart -k`.
- The app **detects** missing FDA rather than assuming it:
  `RecordingsAccessProbe` lists `recordingsDir` and checks for
  `CloudRecordings.db` (without the grant the listing is empty or throws). When
  missing, the status item shows `🎙️⚠️` and the menu grows a "Grant Full Disk
  Access…" item that deep-links to
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` and
  reveals the `.app` in Finder to drag in. There is no API to *request* FDA.
  - A **single negative probe is never trusted** — a denial, a missing
    container, and a listing that merely overran the 500ms deadline all read as
    `false`. At login the cold container regularly overran it, so the app wore
    `🎙️⚠️` with FDA fully granted until the user opened the menu (which
    re-probes) and cleared it. `probeUntilGranted` retries instead — ~34s at
    launch, one confirming retry otherwise — and a completed pipeline run,
    which had to read `CloudRecordings.db`, confirms access outright.
- **The main actor must never touch the filesystem, and `statusItem.menu` must
  never be reassigned after launch.** A main-thread stall while the status menu
  is tracking holds the input grab → system-wide keyboard freeze. Hence: the FDA
  probe runs off-main with a deadline (`BlockingWork.value`; a `withTaskGroup`
  race can't do this — the group awaits hung children), the menu is built once
  and refreshed in `menuNeedsUpdate(_:)` from cached state, and status writes go
  through a serial background queue (flushed synchronously in
  `applicationWillTerminate`).
- **The keyboard freeze actually shipped twice, and the confirmed cause was fd
  exhaustion, not a main-thread stall** (a live `sample` of the wedged process
  showed the main thread idle, which refuted the stall theory). A slow fd leak
  (confirmed 2026-08-20: one fd per abandoned MCP SSE stream — see the MCP
  section's pipelining/keepalive gotcha) hit launchd's 256-fd soft limit; at
  EMFILE, **AppKit itself** failed
  to open its theme/font files during menu open, threw an ObjC exception that
  got swallowed mid-menu-setup (HIToolbox plants a marker thread named
  `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`), and the half-built
  tracking session leaked the window server's keyboard grab. Defenses now in
  place: `FDUsage.raiseLimit()` at launch (256→10240), an fd canary in
  `status.json` (`openFDs`, updated every run), and a watchdog that exits 70
  (KeepAlive respawns) at ≥4096 fds — deferred while the menu is open, because
  dying mid-tracking is the very hazard. When debugging the next freeze: get a
  `sample` of the wedged process *before* killing it, and check `openFDs`.

### MCP server (in-app, for agents)

While the menu-bar app runs it also hosts a **Model Context Protocol** server so
local agents can query transcripts and follow new ones. It runs in the app
process (not the CLI) — the natural home, since the app already has the live
pipeline events to push.

The code lives in its own **`VMIngestMCP` library target**, not in the executable:
Swift cannot import an executable target, so anything defined there is
permanently untestable. Layering within it matters for the same reason —
`TranscriptToolbox` holds the actual tool/resource behaviour as directly
callable methods, while `MCPServerProvider` only registers those on the SDK's
`Server`. Behaviour that lives inside a handler closure can only be exercised by
standing up a real transport; behaviour on the toolbox is a plain function call.
Put new logic in the toolbox, keep the provider thin.

- Transport: Streamable HTTP via the official `swift-sdk` (`MCP` product) with
  NIO fronting the SDK's `StatefulHTTPServerTransport` (`MCPHTTPHost`, adapted
  from the SDK's conformance reference). It is **unauthenticated**, and defaults
  to loopback (`mcpHost`/`mcpPort` = `127.0.0.1:7777`) — but nothing *enforces*
  that: `mcpHost` is passed straight to `bind`, so setting it to `0.0.0.0` would
  expose an open server to the LAN. Keep it on loopback. Note the SDK only
  validates `Origin`/`Host` **when present**, so origin checking is not a
  security boundary (a non-browser client simply omits it). Gated by
  `mcpEnabled` (default true). One MCP `Server` is built per HTTP session by
  `MCPServerProvider`; all sessions share one `TranscriptStore` + one
  `TranscriptEventHub`.
- Reads, never writes: `TranscriptStore` (in `VMIngestCore`, dependency-free)
  queries the canonical `transcripts.jsonl`. The line index is the cursor
  (append-only ⇒ "records after N" == `lines[N...]`).
- Tools: `list_memos`, `search_memos`, `get_memo`, `wait_for_next`,
  `get_status`. Resources: `voicememo://transcripts` (the 100 most recent,
  subscribable) and `voicememo://status` are listed; `voicememo://memo/{id}` is
  readable by direct URI but **not** enumerated — no `ListResourceTemplates`
  handler is registered, so clients discover ids via the tools instead.
- "Subscribe to the next memo" two ways, both fed by `TranscriptEventHub` (the
  app calls `hub.publish(emittedRecords)` after each pipeline run):
  - `wait_for_next` long-poll — attaches its hub listener **before** the first
    store read, then blocks until the next memo or timeout, then **re-reads the
    store** (authoritative). Both halves matter: listening first means a memo
    landing in the read/listen gap still signals (otherwise it would block the
    full timeout despite already being on disk), and the re-read means the
    record itself always comes from the file, never the event.
  - `resources/subscribe` to `voicememo://transcripts` — a per-session pump
    forwards hub events as `notifications/resources/updated` over the session's
    SSE stream.
- Gotcha: an SSE subscriber is *idle by design* — it makes no further requests
  while waiting — so a last-accessed idle reaper will silently kill long-lived
  subscriptions at exactly the timeout. `MCPHTTPHost` therefore counts open
  streams per session and exempts those from reaping, and the NIO handler
  reports the stream closing (including via `channelInactive` on a dropped
  connection, which also cancels the pump so it can't write into a dead
  `ChannelHandlerContext`).
- Gotcha (the fd leak that repeatedly took the app to EMFILE): **an abandoned
  SSE stream is undetectable by reading** — NIO's HTTP pipelining assistance
  pauses reads while a response is in flight, so the peer's FIN/RST is never
  read and `channelInactive` never fires for a client that dies mid-stream.
  Long-polls self-heal at their timeout (response completes → reads resume →
  EOF seen), but an SSE response never completes, so each abandoned subscriber
  held one fd forever (~47/hour under `mcp-remote`'s reconnect cadence; 1285
  CLOSED sockets in 27h, measured). The fix is twofold in the NIO handler:
  every streamed chunk is written with a real promise whose failure closes the
  channel (`promise: nil` swallows delivery failures), and a keepalive SSE
  comment (`: keepalive`) is written every `sseKeepaliveInterval` (default 20s)
  so a dead peer is discovered within ≤2 intervals. `errorCaught` also closes
  explicitly — NIO does not. Regression-tested in `MCPHTTPHostFDTests` with
  raw-socket clients and a milliseconds keepalive.
- Gotcha: MCP `Value.intValue`/`doubleValue` do **not** cross-coerce, so numeric
  tool args (a JSON `2` decodes as `.int`) must be read via the `intArg`/
  `doubleArg` helpers, or e.g. a float-typed `timeout_seconds` silently falls
  back to its default.
- Connecting Claude Desktop: its `claude_desktop_config.json` validator rejects
  the bare `{"type":"http","url":...}` remote form (unlike Claude Code) — it only
  accepts stdio `command` entries, so bridge via `mcp-remote`:
  `{"command":"<abs path to npx>","args":["-y","mcp-remote","http://127.0.0.1:7777/mcp"]}`.
  Use the **absolute** npx path (Claude Desktop launches with a minimal PATH and
  won't find a mise/nvm shim). The server only validates `Origin`/`Host` when
  present, so a non-browser client with no `Origin` connects fine.

**TCC gotchas worth remembering:**

- Whatever process reads the container needs **Full Disk Access**. This is
  per-machine, per-user, and granted manually in System Settings — it cannot be
  bundled or pre-authorized.
- **Apple Notes Automation permission does not work reliably from an unbundled
  CLI binary**: the prompt only surfaces in a foreground TTY and the grant
  doesn't persist for an ad-hoc binary, so a backgrounded run just hangs on it.
  This is why the Note mirror belongs in the signed `.app` (stable identity →
  persistent Automation + notification grants), and why it is disabled by
  default in config.

## Working conventions

- `make check` (build + test + lint) before committing. `make` alone lists
  targets and deliberately does nothing else.
- **Shell scripts must brace every expansion** (`${VAR}`, not `$VAR`), enforced
  by `make lint` via shellcheck's non-default `--enable=require-variable-braces`
  (SC2250). This is not style: an unbraced `$VAR` immediately followed by a
  multibyte character — `echo "Assembling $APP…"` — makes bash read `APP…` as
  the variable name and die with `unbound variable` under `set -u`. It has
  happened twice here. **Default shellcheck does not catch it** (verified: exit
  0); only SC2250 does, which is why the flag is there.
- Keep the runtime LLM-free: this should run as a binary + launchd with no model
  in the loop.
- Roll out slowly: bootstrap-skip the memos that already exist on first run, test
  the full path on a single throwaway recording, and only install the `launchd`
  agent once the manual run is solid.
- Backfill the back-catalog (re-emit memos the first-run bootstrap skipped): stop
  the app, set `seen.json` to `[]` (an empty array — present, so NOT a first run),
  then `vmingest run-once` to emit every memo, and restart the app. Do **not**
  delete `seen.json` to do this: an absent file reads as `isFirstRun` and
  bootstrap-skips everything again (emits 0). To avoid duplicating already-emitted
  lines, seed `seen.json` with the ids already in `transcripts.jsonl` instead of
  `[]` (or clear `transcripts.jsonl` too for a full rebuild).
- Never write to `CloudRecordings.db` or the `.m4a` files — this tool is strictly
  read-only against Apple's data.
- Do not hardcode personal paths beyond `$HOME`; this repo may be open-sourced.
- Build artifacts (the compiled `transcribe` binary, temp DB copies) stay out of
  git.
