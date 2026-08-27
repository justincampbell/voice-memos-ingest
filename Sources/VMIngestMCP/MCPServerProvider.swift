// MCPServerProvider.swift — binds TranscriptToolbox to the MCP SDK.
//
// One Server is built per HTTP session (see MCPHTTPHost). All sessions share the
// same toolbox — and so the same TranscriptStore and TranscriptEventHub — which
// is what lets a single new memo notify every subscribed session. Deliberately
// thin: behaviour lives in TranscriptToolbox, where it can be tested without
// standing up a transport. What's left here is registration plus the
// cross-session bookkeeping the SDK has no opinion about (which sessions are
// alive, and which have a subscription pump running).

import Foundation
import MCP
import VMIngestCore

public actor MCPServerProvider {
    private let toolbox: TranscriptToolbox

    /// Per-session subscription pump. Present ⇒ that session is subscribed to
    /// the transcripts resource and is being pushed resources/updated.
    private var pumps: [String: Task<Void, Never>] = [:]

    public init(config: Config, hub: TranscriptEventHub) {
        self.toolbox = TranscriptToolbox(config: config, hub: hub)
    }

    init(toolbox: TranscriptToolbox) {
        self.toolbox = toolbox
    }

    // MARK: - Server construction (one per HTTP session)

    func makeServer(sessionID: String) async -> Server {
        let server = Server(
            name: MCPNames.serverName,
            version: MCPNames.serverVersion,
            instructions: """
            Read-only access to Apple Voice Memos transcripts ingested by \
            voice-memos-ingest. Use list_memos / search_memos / get_memo to query, \
            and wait_for_next to block until the next memo arrives (pass the cursor \
            you last saw). Clients that support it can instead resources/subscribe to \
            \(MCPNames.transcriptsURI) for push notifications.
            """,
            capabilities: .init(
                resources: .init(subscribe: true, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        let toolbox = self.toolbox

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: TranscriptToolbox.toolDefinitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await toolbox.call(name: params.name, arguments: params.arguments)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: toolbox.resources())
        }
        await server.withMethodHandler(ReadResource.self) { params in
            try toolbox.read(uri: params.uri)
        }

        // Native push: start/stop a pump forwarding hub events as
        // resources/updated for the transcripts URI.
        await server.withMethodHandler(ResourceSubscribe.self) { [weak self, weak server] params in
            guard params.uri == MCPNames.transcriptsURI else {
                throw MCPError.invalidParams("only \(MCPNames.transcriptsURI) is subscribable")
            }
            if let self, let server { await self.startPump(sessionID: sessionID, server: server) }
            return Empty()
        }
        await server.withMethodHandler(ResourceUnsubscribe.self) { [weak self] _ in
            await self?.teardown(sessionID: sessionID)
            return Empty()
        }

        return server
    }

    /// Tear a session down: stop its pump. Called when the HTTP session closes.
    func teardown(sessionID: String) {
        pumps.removeValue(forKey: sessionID)?.cancel()
    }

    /// Begin pushing resources/updated to this session whenever a memo lands.
    /// Idempotent: a second subscribe replaces the existing pump.
    private func startPump(sessionID: String, server: Server) {
        pumps[sessionID]?.cancel()
        let hub = toolbox.hub
        pumps[sessionID] = Task {
            let stream = await hub.listen()
            for await _ in stream {
                if Task.isCancelled { break }
                try? await server.notify(
                    ResourceUpdatedNotification.message(.init(uri: MCPNames.transcriptsURI))
                )
            }
        }
    }

    /// Live subscription-pump count, for tests.
    var pumpCount: Int { pumps.count }
}
