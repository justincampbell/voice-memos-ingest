# Voice Memos channel plugin (push new memos to agents)

Instead of each agent running a `Monitor` on `transcripts.jsonl`, or a cron/loop
polling `wait_for_next`, this is a Claude Code **channel**: a session launched
with the channel flag receives every newly transcribed memo as an inbound
message, the moment it is ingested. One bridge serves every subscribed session.

```
iPhone/Watch ─▶ iCloud ─▶ menu-bar app (ingest + MCP server :7777)
                                    │ wait_for_next (push)
                                    ▼
                              vmchannel  ──stdio──▶  Claude Code session
                           (this plugin)   notifications/claude/channel
```

`vmchannel` is a channel MCP server on the Claude Code side and an MCP **client**
to the resident app's loopback server on the data side. It reuses the push edge
the app already hosts (`wait_for_next`), so there is no new watcher or poll loop,
and it needs the menu-bar app running with `mcpEnabled` (the default).

## Setup (one time)

1. **Build and install the binary** (it is a build artifact, not committed):

   ```sh
   make install-channel        # → ~/.local/bin/vmchannel
   ```

   It has to live somewhere stable: Claude Code runs an installed plugin from a
   **copy** under `~/.claude/plugins/cache/`, so `run.sh` can't reach this repo's
   `.build/`. It looks for `$VMCHANNEL_BIN`, then `~/.local/bin/vmchannel`, then
   (only when run straight from a checkout) `.build/{release,debug}`, then `PATH`.
   Re-run this after changing the Swift code.

2. **Register this repo as a plugin marketplace** and install the plugin:

   ```sh
   claude plugin marketplace add /path/to/voice-memos-ingest
   claude plugin install voice-memos@voice-memos-ingest
   ```

   (`voice-memos-ingest` is the marketplace name from the repo-root
   `.claude-plugin/marketplace.json`; `voice-memos` is the plugin.) After
   changing anything under `channel/`, bump `version` in `plugin.json` and run
   `claude plugin update voice-memos@voice-memos-ingest` — the cached copy is
   keyed on the version.

3. **Launch a session subscribed to the channel.** The channel server only
   connects when the session is started with a channel flag — and it must be
   the *development* one:

   ```sh
   claude --dangerously-load-development-channels plugin:voice-memos@voice-memos-ingest
   ```

   During the channels research preview, plain `--channels` accepts only
   Anthropic's allowlist (the channel plugins in `claude-plugins-official`); a
   local plugin passed to it starts nothing and shows *"not on the approved
   channels allowlist"*. There is no user setting to add to that list (the
   `allowedChannelPlugins` key is managed-settings-only, for Team/Enterprise
   admins). The development flag skips the allowlist for the entries passed to
   it, shows a one-time warning to accept, and only works in an **interactive**
   session — it's ignored under `-p`.

That session now receives each new memo as a message like:

```
<channel source="voice-memos" chat_id="voice-memos" message_id="449C08DD" …>
Idea: let agents subscribe to new memos via channels instead of polling.
</channel>
```

The transcript is the message content; the memo's `title`, `ts` (recorded time),
`duration`, and `transcript_source` (`apple` | `speechtranscriber`) ride in the
notification `meta`. (Not `source`: the envelope already has a `source`
attribute naming the channel.)

## One-way feed

There is no human on the other end of a voice memo, so this channel is inbound
only. The contract still requires a `reply` tool, so one exists — but it only
logs the text to stderr and discards it. Act on each memo per your own
instructions (route it, capture reminders, etc.); don't reply expecting someone
to read it.

## Config

`vmchannel` reads the same `~/.config/voice-memos-ingest/config.json` as the rest
of the tool, and reaches the resident server at `mcpHost:mcpPort`
(`127.0.0.1:7777` by default). No channel-specific config.
