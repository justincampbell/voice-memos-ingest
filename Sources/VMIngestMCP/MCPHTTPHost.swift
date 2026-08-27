// MCPHTTPHost.swift — a loopback Streamable-HTTP host for the MCP server.
//
// Adapted from the swift-sdk MCPConformance reference HTTP app (the SDK ships the
// StatefulHTTPServerTransport but not a public HTTP listener). One MCP session per
// client: a POST `initialize` mints a session id; subsequent POSTs carry it; a GET
// opens the standalone SSE stream the server pushes notifications down; DELETE ends
// it. Each session gets its own Server from MCPServerProvider, but they share the
// store + event hub, so a single new memo notifies every subscribed session.
//
// Bind to 127.0.0.1 only: this endpoint is unauthenticated and intended solely for
// local agents on this machine.

import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1
import VMIngestCore

public actor MCPHTTPHost {
    private let host: String
    private let port: Int
    private let endpoint: String
    private let provider: MCPServerProvider
    private let sessionTimeout: TimeInterval = 3600

    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var sessions: [String: SessionContext] = [:]

    nonisolated let logger = Logger(label: "voicememos.mcp.http")

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccessedAt: Date
        /// Open SSE streams for this session. A subscribed client is idle by
        /// design — it makes no requests while waiting — so it must not be
        /// reaped for inactivity; the connection dropping is what ends it.
        var openStreams: Int = 0
    }

    /// How often an open SSE stream writes a keepalive comment. This is fd
    /// hygiene, not politeness: the HTTP pipeline pauses reads while a response
    /// is in flight, so a vanished subscriber is undetectable until we *write*
    /// — without the ping, every abandoned SSE stream leaked one fd forever
    /// (1285 of them took the app to EMFILE; see CLAUDE.md's MCP notes).
    /// Injectable so tests can run it at milliseconds.
    nonisolated let sseKeepaliveInterval: Duration

    public init(config: Config, hub: TranscriptEventHub, sseKeepaliveInterval: Duration = .seconds(20)) {
        self.host = config.mcpHost
        self.port = config.mcpPort
        self.endpoint = "/mcp"
        self.provider = MCPServerProvider(config: config, hub: hub)
        self.sseKeepaliveInterval = sseKeepaliveInterval
    }

    var mcpEndpoint: String { endpoint }

    // MARK: - Lifecycle

    /// Bind and start accepting connections in the background. Returns once the
    /// socket is bound (or throws if the bind fails, e.g. port in use).
    public func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(host: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel = channel
        logger.info("MCP HTTP server listening on http://\(host):\(port)\(endpoint)")
        Task { await sessionCleanupLoop() }
    }

    public func stop() async {
        for id in Array(sessions.keys) { await closeSession(id) }
        try? await channel?.close()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
    }

    // MARK: - Request routing

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await closeSession(sessionID)
            }
            return response
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           Self.isInitializeRequest(body) {
            return await createSessionAndHandle(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Session not found or expired"))
        }
        return .error(statusCode: 400, .invalidRequest("Missing \(HTTPHeaderName.sessionID) header"))
    }

    /// A session is born from a JSON-RPC `initialize` request (the SDK's own
    /// classifier is internal, so we sniff the method ourselves).
    private static func isInitializeRequest(_ body: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return obj["method"] as? String == "initialize"
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            logger: logger
        )
        let server = await provider.makeServer(sessionID: sessionID)
        do {
            try await server.start(transport: transport)
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("session start failed: \(error)"))
        }
        sessions[sessionID] = SessionContext(server: server, transport: transport, lastAccessedAt: Date())

        let response = await transport.handleRequest(request)
        if case .error = response { await closeSession(sessionID) }
        return response
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await provider.teardown(sessionID: sessionID)
        await session.server.stop()
        await session.transport.disconnect()
    }

    /// Track an SSE stream opening/closing for a session. Called by the NIO
    /// handler around the streaming write, and on connection drop.
    func markStreaming(_ sessionID: String, open: Bool) {
        guard var session = sessions[sessionID] else { return }
        session.openStreams = max(0, session.openStreams + (open ? 1 : -1))
        session.lastAccessedAt = Date()
        sessions[sessionID] = session
    }

    private func sessionCleanupLoop() async {
        while channel != nil {
            try? await Task.sleep(for: .seconds(60))
            let now = Date()
            // Skip sessions holding an open SSE stream: they are legitimately
            // idle (waiting for a memo), and reaping them silently killed
            // long-lived subscribers at exactly the timeout.
            let expired = sessions.filter {
                $0.value.openStreams == 0 && now.timeIntervalSince($0.value.lastAccessedAt) > sessionTimeout
            }
            for (id, _) in expired { await closeSession(id) }
        }
    }
}

// MARK: - NIO adapter

/// Thin NIO handler: buffers a request, converts to HTTPRequest, hands it to the
/// host, and writes back HTTPResponse — including streaming SSE bodies.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let host: MCPHTTPHost

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }
    private var requestState: RequestState?

    /// The in-flight request task, and the session whose SSE stream it is
    /// pumping (if any). Both are needed to unwind cleanly when the client
    /// disconnects: NIO forbids touching a context after the handler is gone.
    private var activeTask: Task<Void, Never>?
    private var streamingSessionID: String?

    init(host: MCPHTTPHost) { self.host = host }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestState = RequestState(head: head, bodyBuffer: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil
            nonisolated(unsafe) let ctx = context
            activeTask = Task { await self.handle(state: state, context: ctx) }
        }
    }

    /// Client went away: stop the pump so it can't write into a dead context,
    /// and release the session's stream hold so it can be reaped normally.
    func channelInactive(context: ChannelHandlerContext) {
        unwind()
        context.fireChannelInactive()
    }

    /// A channel error (connection reset mid-request, parse failure, …) does
    /// NOT close the channel by default — leaving it open leaks the fd. Unwind
    /// and close explicitly.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        unwind()
        context.close(promise: nil)
    }

    private func unwind() {
        activeTask?.cancel()
        activeTask = nil
        if let sessionID = streamingSessionID {
            streamingSessionID = nil
            let host = self.host
            Task { await host.markStreaming(sessionID, open: false) }
        }
    }

    private func handle(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await host.mcpEndpoint
        guard path == endpoint else {
            await write(.error(statusCode: 404, .invalidRequest("Not Found")), version: head.version, context: context)
            return
        }
        let request = makeRequest(from: state)
        let response = await host.handleHTTPRequest(request)

        // A streaming response is an SSE stream that stays open; hold the
        // session open for as long as it lasts.
        var heldSessionID: String?
        if case .stream = response, let sessionID = request.header(HTTPHeaderName.sessionID) {
            heldSessionID = sessionID
            streamingSessionID = sessionID
            await host.markStreaming(sessionID, open: true)
        }

        await write(response, version: head.version, context: context)

        if let heldSessionID, streamingSessionID == heldSessionID {
            streamingSessionID = nil
            await host.markStreaming(heldSessionID, open: false)
        }
    }

    private struct ContextBox: @unchecked Sendable { let ctx: ChannelHandlerContext }

    /// Write one body chunk with a real promise; on failure, close the channel
    /// so the fd is released. `promise: nil` writes swallow delivery failures,
    /// which is exactly how dead-subscriber fds used to accumulate.
    private func writeBodyOrClose(_ bytes: [UInt8], ctx context: ChannelHandlerContext) {
        nonisolated(unsafe) let ctx = context
        ctx.eventLoop.execute {
            var buffer = ctx.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            let promise = ctx.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenFailure { _ in ctx.close(promise: nil) }
            ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        }
    }

    private func makeRequest(from state: RequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let body: Data? = state.bodyBuffer.readableBytes > 0
            ? state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes).map { Data($0) }
            : nil
        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        return HTTPRequest(method: state.head.method.rawValue, headers: headers, body: body, path: path)
    }

    private func write(_ response: HTTPResponse, version: HTTPVersion, context: ChannelHandlerContext) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop
        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: statusCode))
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }
            // Pump events and, concurrently, ping. The ping is what discovers a
            // dead subscriber: the pipeline pauses reads during a response, so
            // the peer's FIN/RST is never read and channelInactive never fires
            // on its own — an abandoned stream otherwise holds its fd forever.
            // A failed write closes the channel (see writeBodyOrClose); a
            // FIN-closed peer fails on the second ping (the first send lands in
            // the kernel and draws the RST), so detection takes ≤2 intervals.
            let keepalive = host.sseKeepaliveInterval
            // Safe: every use of the boxed context hops to its event loop.
            let box = ContextBox(ctx: ctx)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    do {
                        for try await chunk in stream {
                            // channelInactive cancels this task when the client
                            // drops; bail before writing into a context NIO may
                            // have torn down.
                            if Task.isCancelled { break }
                            writeBodyOrClose(Array(chunk), ctx: box.ctx)
                        }
                    } catch {}
                }
                group.addTask { [self] in
                    let ping = Array(": keepalive\n\n".utf8)  // SSE comment; clients ignore it
                    while !Task.isCancelled {
                        try? await Task.sleep(for: keepalive)
                        if Task.isCancelled { break }
                        writeBodyOrClose(ping, ctx: box.ctx)
                    }
                }
                await group.next()  // the pump finishing (or cancellation) ends the response
                group.cancelAll()
            }
            if !Task.isCancelled {
                eventLoop.execute { ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil) }
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: statusCode))
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
