# voice-memos-ingest

Watches Apple Voice Memos and appends every new transcript to an append-only
JSONL file, so scripts and agents can act on your voice notes automatically.

No LLM, no cloud service, no outbound network. Transcription is Apple's
on-device engine; the only socket opened is an optional loopback MCP server for
local agents.

```
Record on iPhone / Apple Watch / Mac
  → recording (and usually its transcript) syncs to the Mac via iCloud
  → this tool extracts or generates the transcript, appends one JSON line
  → your script or agent reads the new lines and does something with them
```

> **Status: early.** Works end-to-end — signed `.app`, LaunchAgent autostart,
> MCP server — but only tested on the author's Mac (macOS 26.2, Apple Silicon).
> Signing is self-signed, which is fine for a machine you build on and *not*
> enough for distribution (Gatekeeper blocks a downloaded build without a
> Developer ID signature + notarization). So: build from source.

## Requirements

- macOS 26 (Tahoe) or later — it uses the `SpeechAnalyzer` / `SpeechTranscriber`
  API introduced there. Verified on 26.2, Apple Silicon.
- A Swift 6.x toolchain (Xcode 16+ or the Command Line Tools).
- **Full Disk Access**, granted manually — see the install steps.

## Install

```sh
make install     # build + code-sign the .app, install to ~/Applications,
                 # and load the LaunchAgent so it starts at login
```

Then grant **Full Disk Access** to `~/Applications/VoiceMemosIngest.app`:

> System Settings → Privacy & Security → **Full Disk Access** → **+** → pick the
> app (⌘⇧G to paste the path). Then restart it:
> `launchctl kickstart -k gui/$(id -u)/me.justincampbell.voice-memos-ingest`

Without it, the Voice Memos directory reads as empty and everything fails with
"Operation not permitted". There is no API to request this grant, so the app
detects when it's missing: the menu-bar icon becomes 🎙️⚠️ and grows a "Grant
Full Disk Access…" item that opens the right Settings pane and reveals the app
in Finder for you to drag in.

A 🎙️ icon in the menu bar means it's watching. Its menu shows watch state, total
emitted, the last memo, and the last error.

**First run bootstraps**: every memo that already exists is recorded as "already
seen" and nothing is emitted, so you don't dump your whole back-catalog into the
file. Record a new memo, wait a few seconds for iCloud, and you'll get exactly
one new line.

Remove with `make uninstall` (leaves the app and your data in place).

> The `.app` is code-signed because macOS keys Full Disk Access to the code
> signature — an *unsigned* rebuild resets the grant every single time.
> `packaging/package.sh` uses a free self-signed certificate and prints
> instructions for creating it if you don't have one. No Apple Developer account
> needed.

## Output

The canonical output is an append-only JSONL file, by default
`~/.local/share/voice-memos-ingest/transcripts.jsonl`. One self-contained object
per line; existing lines are never rewritten.

```json
{"id":"…","recorded_at":"2026-06-16T15:02:25Z","duration":3.2,"title":"…","source":"apple","text":"Test, test, 123 test.","transcribed_at":"2026-06-16T15:05:37Z"}
```

`source` is `apple` when Apple's own transcript was embedded in the recording, or
`speechtranscriber` when this tool generated one. With `alwaysDoubleTranscribe`
enabled, both are recorded as `apple_text` and `our_text`.

Because the file is append-only, a consumer just remembers a **byte offset**:
read from the saved offset to EOF, handle the new lines, save the new offset.
That's the whole protocol — no locking, no database:

```sh
#!/usr/bin/env bash
set -euo pipefail
FILE="${HOME}/.local/share/voice-memos-ingest/transcripts.jsonl"
CURSOR="${HOME}/.local/state/my-consumer.offset"

offset=$(cat "${CURSOR}" 2>/dev/null || echo 0)
size=$(stat -f%z "${FILE}")
[ "${size}" -le "${offset}" ] && exit 0          # nothing new

tail -c "+$((offset + 1))" "${FILE}" | while IFS= read -r line; do
    printf '%s\n' "${line}" | jq -r '.text'
done

mkdir -p "$(dirname "${CURSOR}")"
printf '%s' "${size}" > "${CURSOR}"
```

## MCP server (for agents)

While the menu-bar app runs it hosts a **Model Context Protocol** server over
Streamable HTTP at `http://127.0.0.1:7777/mcp`, reading the same JSONL. Agents
can query and follow transcripts without parsing files themselves.

```sh
claude mcp add --transport http voice-memos http://127.0.0.1:7777/mcp
```

| Tool            | Purpose                                                        |
|-----------------|----------------------------------------------------------------|
| `list_memos`    | recent transcripts, newest first (`limit`)                     |
| `search_memos`  | case-insensitive substring search over text/title (`query`, `limit`) |
| `get_memo`      | one transcript by id (`id`)                                    |
| `wait_for_next` | **block until the next memo** (`after_cursor`, `timeout_seconds`) |
| `get_status`    | watcher status (running, totals, last error)                   |

To follow new memos, either long-poll `wait_for_next` — omit `after_cursor` to
wait for the genuinely next one, then loop passing back the `cursor` it returns —
or, from an SSE-capable client, `resources/subscribe` to
`voicememo://transcripts` and get `notifications/resources/updated` the moment a
memo lands. Passing an older cursor to `wait_for_next` returns the backlog
immediately, so a consumer that was offline catches up.

`resources/list` advertises `voicememo://transcripts` (100 most recent) and
`voicememo://status`. `voicememo://memo/{id}` is readable by direct URI but
deliberately not enumerated — discover ids with the tools.

> The server is **unauthenticated** and meant for local agents only. `mcpHost`
> defaults to `127.0.0.1` and nothing enforces that — pointing it at another
> interface publishes your transcripts to that network. Leave it on loopback, or
> set `"mcpEnabled": false`.

## CLI

`vmingest` is for headless use, scripting, and debugging.

```sh
swift run vmingest run-once                # run the pipeline once, headless
swift run vmingest status                  # what the menu-bar app last did
swift run vmingest config                  # resolved config, and its file path
swift run vmingest list                    # memos in Apple's index (debug)
swift run vmingest transcribe <file.m4a>   # on-device transcript of one file
swift run vmingest tsrp       <file.m4a>   # Apple's embedded transcript, if any
```

Running it from a terminal means *that terminal* needs Full Disk Access, granted
the same way as the app.

## Configuration

Optional, from `~/.config/voice-memos-ingest/config.json`. Anything absent falls
back to the default — `vmingest config` prints what's actually in effect.

| Key                      | Default                                | Meaning                                             |
|--------------------------|----------------------------------------|-----------------------------------------------------|
| `recordingsDir`          | Voice Memos group container            | where Apple's recordings + index live (read-only)   |
| `transcriptsPath`        | `~/.local/share/.../transcripts.jsonl` | canonical append-only output                        |
| `seenPath`               | `~/.local/share/.../seen.json`         | which memos have been emitted                       |
| `statusPath`             | `~/.local/share/.../status.json`       | status the app maintains, the CLI reads             |
| `alwaysDoubleTranscribe` | `false`                                | also run our transcriber when Apple's is present    |
| `localeIdentifier`       | `en-US`                                | transcription locale                                |
| `appleNoteEnabled`       | `false`                                | mirror into an Apple Note — ⚠️ see below             |
| `appleNoteName`          | `Voice Memo Transcripts`               | the note to append to (use a dedicated one)         |
| `mcpEnabled`             | `true`                                 | host the MCP server (menu-bar app only)             |
| `mcpHost`                | `127.0.0.1`                            | MCP bind address — keep on loopback                 |
| `mcpPort`                | `7777`                                 | MCP TCP port                                        |

This tool is strictly **read-only** against Apple's data: it never writes to
`CloudRecordings.db` or to any `.m4a`.

## Apple Note mirror (optional)

Off by default. Appends each transcript to a single note as a human-readable
mirror — a convenience, never the source of truth, since a note is mutable and
has no clean cursor.

> ⚠️ **Point it at a dedicated note only.** The built-in mirror appends via
> AppleScript `set body of note`, which re-renders the note's HTML and
> **destroys checklists, tables, and attachments**. Safe on a note this tool
> owns; destructive on one you care about.

The safe way to append to a note you care about is Apple Shortcuts' native
"Append to Note" action, which preserves that formatting. `router/append-note.sh`
wraps it and `router/shortcut.md` has the one-time setup. That path is currently
standalone — the Swift pipeline still uses the legacy AppleScript mirror.

## Development

```sh
make            # list targets; does nothing else
make build      # swift build
make test       # swift test
make lint       # shellcheck over every tracked shell script
make check      # all three — the pre-commit sweep
```

`make lint` needs `brew install shellcheck`, and fails loudly rather than
silently passing if it's missing.

[`CLAUDE.md`](CLAUDE.md) has the research and design notes: where Apple actually
hides the transcript, why the database must be copied before reading, the TCC
and packaging findings, and the threading rules the menu-bar app has to obey.

## License

MIT — see [LICENSE](LICENSE).
