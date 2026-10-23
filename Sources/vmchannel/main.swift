// vmchannel — the Claude Code channel-plugin server for voice-memos-ingest.
//
// Launched by Claude Code (via channel/.mcp.json) when a session starts with
//   claude --channels plugin:voice-memos@<marketplace>
// It speaks the `claude/channel` contract over stdio and pushes each newly
// ingested voice memo into the session as a message — no polling, no Monitor,
// no cron on the agent's side. New memos are learned from the resident app's
// loopback MCP server (`wait_for_next`); so the menu-bar app must be running
// with mcpEnabled (the default).
//
// Thin by design: all logic is in the importable, tested VMIngestChannel
// library. This executable only loads config and wires the pieces together.

import Foundation
import VMIngestChannel
import VMIngestCore

let config = (try? Config.load()) ?? Config.defaults()

let proto = ChannelProtocol()
let source = WaitForNextMemoSource(host: config.mcpHost, port: config.mcpPort)
let writer = StdoutWriter()
let server = ChannelServer(proto: proto, source: source, writer: writer)

FileHandle.standardError.write(Data(
    "vmchannel: voice-memos channel starting; memos from http://\(config.mcpHost):\(config.mcpPort)/mcp\n".utf8
))

await server.run()
