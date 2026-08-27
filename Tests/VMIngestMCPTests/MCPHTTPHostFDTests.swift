import XCTest
import Foundation
@testable import VMIngestCore
@testable import VMIngestMCP

/// Regression test for the fd leak that took the app to EMFILE (and froze the
/// machine's keyboard): a client that abandons an open SSE stream was never
/// detected — the HTTP pipeline pauses reads mid-response, so the FIN was
/// never read and the connection's fd lived forever. The keepalive ping now
/// discovers the dead peer and closes the channel.
final class MCPHTTPHostFDTests: XCTestCase {
    private var tempDir: URL!
    private var host: MCPHTTPHost!
    private var port = 0

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-fd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data().write(to: tempDir.appendingPathComponent("transcripts.jsonl"))

        // Ephemeral-ish port; retry a few times in case of collision.
        for attempt in 0..<5 {
            port = Int.random(in: 30000..<60000)
            let config = Config(
                recordingsDir: tempDir.path,
                transcriptsPath: tempDir.appendingPathComponent("transcripts.jsonl").path,
                seenPath: tempDir.appendingPathComponent("seen.json").path,
                statusPath: tempDir.appendingPathComponent("status.json").path,
                appleNoteName: "test", appleNoteEnabled: false,
                alwaysDoubleTranscribe: false, localeIdentifier: "en-US",
                mcpEnabled: true, mcpHost: "127.0.0.1", mcpPort: port
            )
            host = MCPHTTPHost(config: config, hub: TranscriptEventHub(), sseKeepaliveInterval: .milliseconds(100))
            do { try await host.start(); return } catch where attempt < 4 { continue }
        }
    }

    override func tearDown() async throws {
        await host?.stop()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Raw-socket helpers (URLSession can't abandon a connection)

    private func connect() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(fd); throw XCTSkip("connect failed: \(errno)") }
        return fd
    }

    private func send(_ fd: Int32, _ text: String) {
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    private func recvString(_ fd: Int32, max: Int = 8192) -> String {
        var buf = [UInt8](repeating: 0, count: max)
        let n = read(fd, &buf, max)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }

    private func request(_ fd: Int32, method: String, headers: [String: String], body: String? = nil) {
        var text = "\(method) /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        if let body { text += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)" } else { text += "\r\n" }
        send(fd, text)
    }

    /// Initialize an MCP session over a throwaway connection; return its id.
    private func makeSession() throws -> String {
        let fd = try connect()
        defer { close(fd) }
        request(fd, method: "POST", headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ], body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)
        let response = recvString(fd)
        guard let range = response.range(of: "(?im)^mcp-session-id:\\s*(\\S+)", options: .regularExpression) else {
            XCTFail("no session id in: \(response.prefix(200))"); return ""
        }
        return String(response[range].split(separator: ":")[1]).trimmingCharacters(in: .whitespaces)
    }

    /// Open a real SSE stream for the session and return the connected fd.
    private func openSSE(session: String) throws -> Int32 {
        let fd = try connect()
        request(fd, method: "GET", headers: [
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2025-06-18",
            "Mcp-Session-Id": session,
        ])
        let head = recvString(fd, max: 1024)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), "SSE stream should open, got: \(head.prefix(80))")
        return fd
    }

    private func fdCount() throws -> Int {
        try XCTUnwrap(FDUsage.count())
    }

    // MARK: - Tests

    /// The core regression: abandoned SSE subscribers must not retain fds.
    /// With a 100ms keepalive, the dead peer is discovered within ~2 pings.
    func testAbandonedSSEStreamsReleaseFDs() async throws {
        let baseline = try fdCount()

        for _ in 0..<3 {
            let session = try makeSession()
            let sse = try openSSE(session: session)
            close(sse)  // client vanishes; server is mid-response with reads paused
        }

        // Give the keepalive a few cycles to notice and close the channels.
        var current = try fdCount()
        for _ in 0..<50 where current > baseline {
            try await Task.sleep(for: .milliseconds(100))
            current = try fdCount()
        }
        XCTAssertLessThanOrEqual(
            current, baseline,
            "abandoned SSE connections must be closed by the keepalive ping"
        )
    }

    /// A live subscriber must NOT be killed by the keepalive — pings flow to
    /// it harmlessly (SSE comments), and the stream stays open.
    func testLiveSSEStreamSurvivesKeepalive() async throws {
        let session = try makeSession()
        let sse = try openSSE(session: session)
        defer { close(sse) }

        try await Task.sleep(for: .milliseconds(500))  // ~5 keepalive intervals

        // The connection is still writable from the server (we can still read),
        // and the pings arrive as SSE comments.
        let data = recvString(sse)
        XCTAssertTrue(data.contains(": keepalive"), "expected keepalive comments, got: \(data.prefix(120))")
    }
}
