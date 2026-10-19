import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CanvasCore

@Suite(.serialized)
@MainActor
struct HostHTTPTests {
    @Test func aBodyStreamsAfterItsHeadInBoundedChunks() async throws {
        let host = try await ScratchHost()
        defer { host.close() }
        let fetched = try await host.fetch(HostHTTPRequest(url: host.url("/body")))
        let head = try #require(fetched.heads.first)
        #expect(fetched.heads.count == 1 && !fetched.bytesBeforeHead)
        #expect(head.status == 200 && head.url == host.url("/body"))
        #expect(head.headers["content-type"] == "application/octet-stream")
        #expect(head.headers["content-length"] == "300000")
        #expect(head.headers["x-frame-options"] == "DENY", "embedding protections stay visible")
        #expect(head.headers["set-cookie"] == nil && head.headers["keep-alive"] == nil && head.headers["connection"] == nil)
        #expect(fetched.chunks.count > 1)
        #expect(fetched.chunks.allSatisfy { (1...HostHTTP.chunk).contains($0) })
        #expect(fetched.chunks.reduce(0, +) == ScratchHost.size)
        #expect(fetched.digest == SHA256.hash(data: ScratchHost.body))
        #expect(host.requests == [Upstream(port: host.port, method: "GET", path: "/body", headers: ["accept-encoding", "host"], range: nil)])
    }

    @Test func headRangeAndErrorStatusesKeepTheUpstreamAnswer() async throws {
        let host = try await ScratchHost()
        defer { host.close() }
        let head = try await host.fetch(HostHTTPRequest(url: host.url("/body"), method: "HEAD"))
        #expect(head.heads.map(\.status) == [200] && head.chunks.isEmpty)
        #expect(head.heads.first?.headers["content-length"] == "300000")
        let range = try await host.fetch(HostHTTPRequest(url: host.url("/body"), range: "bytes=10-19"))
        #expect(range.heads.map(\.status) == [206])
        #expect(range.heads.first?.headers["content-range"] == "bytes 10-19/300000")
        #expect(range.heads.first?.headers["content-length"] == "10")
        #expect(range.body == ScratchHost.body.subdata(in: 10..<20))
        let missing = try await host.fetch(HostHTTPRequest(url: host.url("/missing")))
        #expect(missing.heads.map(\.status) == [404] && missing.body == Data("missing\n".utf8))
        #expect(host.requests == [
            Upstream(port: host.port, method: "HEAD", path: "/body", headers: ["accept-encoding", "host"], range: nil),
            Upstream(port: host.port, method: "GET", path: "/body", headers: ["accept-encoding", "host", "range"], range: "bytes=10-19"),
            Upstream(port: host.port, method: "GET", path: "/missing", headers: ["accept-encoding", "host"], range: nil),
        ])
    }

    @Test func gzipBodiesAreDecodedAndOtherEncodingsRefused() async throws {
        let host = try await ScratchHost()
        defer { host.close() }
        let decoded = try await host.fetch(HostHTTPRequest(url: host.url("/gzip")))
        let head = try #require(decoded.heads.first)
        #expect(head.status == 200 && head.headers["content-type"] == "text/plain")
        #expect(head.headers["content-encoding"] == nil && head.headers["content-length"] == nil)
        #expect(decoded.body == Data(String(repeating: "compressed text\n", count: 1000).utf8))
        await #expect(throws: HostFileError.unavailable("unsupported content encoding br")) {
            try await host.fetch(HostHTTPRequest(url: host.url("/brotli")))
        }
    }

    @Test func redirectsAreFollowedOnlyToAllowedAuthorities() async throws {
        let host = try await ScratchHost()
        defer { host.close() }
        let followed = try await host.fetch(HostHTTPRequest(url: host.url("/redirect"), range: "bytes=0-9"))
        #expect(followed.heads.map(\.url) == [host.url("/body")])
        #expect(followed.heads.map(\.status) == [206] && followed.body == ScratchHost.body.subdata(in: 0..<10))
        await #expect(throws: HostFileError.refused) { try await host.fetch(HostHTTPRequest(url: host.url("/away"))) }
        await #expect(throws: HostFileError.unavailable("too many redirects")) {
            try await host.fetch(HostHTTPRequest(url: host.url("/loop")))
        }
        let ranged = ["accept-encoding", "host", "range"], plain = ["accept-encoding", "host"]
        let loop = Upstream(port: host.port, method: "GET", path: "/loop", headers: plain, range: nil)
        #expect(host.requests == [
            Upstream(port: host.port, method: "GET", path: "/redirect", headers: ranged, range: "bytes=0-9"),
            Upstream(port: host.port, method: "GET", path: "/body", headers: ranged, range: "bytes=0-9"),
            Upstream(port: host.port, method: "GET", path: "/away", headers: plain, range: nil),
        ] + Array(repeating: loop, count: HostHTTP.redirects + 1))
    }

    @Test func crossOriginRedirectCannotBorrowItsRequestingOrigin() async throws {
        let host = try await ScratchHost()
        defer { host.close() }
        await #expect(throws: HostFileError.refused) {
            try await host.files.http(HostHTTPRequest(url: host.url("/away")),
                                      allow: host.allow + ["127.0.0.1:\(host.other)"]) { _ in }
        }
        #expect(host.requests == [
            Upstream(port: host.port, method: "GET", path: "/away", headers: ["accept-encoding", "host"], range: nil)
        ])
    }

    @Test func refusedRequestsNeverStartTheHostClient() async throws {
        let host = try await ScratchHost()
        defer { host.close() }
        let refused = [
            HostHTTPRequest(url: host.url("/secret", port: host.other)),
            HostHTTPRequest(url: try #require(URL(string: "http://localhost:\(host.port)/body"))),
            HostHTTPRequest(url: try #require(URL(string: "http://viewer@127.0.0.1:\(host.port)/body"))),
            HostHTTPRequest(url: try #require(URL(string: "file:///etc/hosts"))),
            HostHTTPRequest(url: host.url("/body"), method: "POST"),
            HostHTTPRequest(url: host.url("/body"), range: "bytes=0-1\r\nCookie: viewer=1"),
        ]
        for request in refused {
            await #expect(throws: HostFileError.refused) { try await host.fetch(request) }
        }
        #expect(host.clientPID == nil && host.requests.isEmpty)
        _ = try await host.fetch(HostHTTPRequest(url: host.url("/missing")))
        #expect(host.clientPID != nil && host.requests.map(\.path) == ["/missing"])
    }

    @Test func cancellingAPausedStreamReapsItsClientAndGivesBackItsSession() async throws {
        let host = try await ScratchHost()
        defer { host.close() }
        let paused = Locked(false)
        let task = Task {
            try await host.files.http(HostHTTPRequest(url: host.url("/large")), allow: host.allow) { event in
                guard case .bytes = event else { return }
                paused.withLock { $0 = true }
                try await Task.sleep(for: .seconds(60))
            }
        }
        defer { task.cancel() }
        try #require(await eventually { paused.withLock { $0 } }, "the first chunk reached the consumer")
        let pid = try #require(host.clientPID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.large?.outcome == nil, "a paused consumer holds the upstream producer back")

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "the ssh client was reaped")
        try #require(await eventually { host.large != nil })
        let large = try #require(host.large)
        #expect(large.outcome == "aborted" && large.sent < ScratchHost.largeBytes, "the host's HTTP client closed its connection")

        #expect(try await host.fetch(HostHTTPRequest(url: host.url("/missing"))).heads.map(\.status) == [404])
    }
}

private struct Upstream: Decodable, Equatable {
    var port: Int
    var method: String
    var path: String
    var headers: [String]
    var range: String?
}

private struct Large: Decodable {
    var outcome: String
    var sent: Int
}

private struct Fetched {
    var heads: [HostHTTPHead] = []
    var chunks: [Int] = []
    var body = Data()
    var hasher = SHA256()
    var bytesBeforeHead = false
    var digest: SHA256.Digest { hasher.finalize() }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
private final class ScratchHost {
    static let size = 300_000
    static let largeBytes = 48 * 1024 * 1024
    static let body = Data((0..<size).map { UInt8($0 % 251) })

    let fixture: HostFileFixture
    let processes: RemoteProcesses
    let master: HostMaster
    let files: HostFiles
    let server: Process
    let port: Int
    let other: Int

    init() async throws {
        let fixture = try HostFileFixture()
        let ssh = try await fixture.reader(body: """
        for argument; do
          case $argument in
            -O) exit 0 ;;
            -M) exec /bin/sleep 60 ;;
          esac
        done
        echo $$ > \(RemoteHost.quote(fixture.directory.appendingPathComponent("client.pid").path))
        exec /bin/sh -c "$command"
        """).channel("", [])
        try #require(ssh.arguments.count > 1 && ssh.arguments[0] == "-S")
        let processes = RemoteProcesses()
        let master = HostMaster(route: HostRoute(target: "fixture", controlPath: ssh.arguments[1], executable: ssh.executable), processes: processes)
        try FileManager.default.copyItem(atPath: ssh.arguments[1], toPath: master.fileReader.route.controlPath)
        let server = Process()
        let diagnosticURL = fixture.directory.appendingPathComponent("server.stderr")
        try Data().write(to: diagnosticURL)
        let diagnostic = try FileHandle(forWritingTo: diagnosticURL)
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-I", "-S", "-B", "-c", Self.upstream, fixture.directory.path, String(Self.size), String(Self.largeBytes)]
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        server.standardError = diagnostic
        try server.run()
        try diagnostic.close()
        let published = fixture.directory.appendingPathComponent("ports")
        let started = try await eventually { FileManager.default.fileExists(atPath: published.path) || !server.isRunning }
        let ports = ((try? String(contentsOf: published, encoding: .utf8)) ?? "").split(separator: " ").compactMap { Int($0) }
        var failure = ""
        if !started || ports.count != 2 {
            let wasRunning = server.isRunning
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
            let reader = try FileHandle(forReadingFrom: diagnosticURL)
            let data = try reader.read(upToCount: 8192) ?? Data()
            try reader.close()
            failure = "server \(server.processIdentifier) runningBeforeCleanup=\(wasRunning) exit \(server.terminationStatus): " + String(decoding: data, as: UTF8.self)
        }
        try #require(started && ports.count == 2, "the scratch server published its ports; \(failure)")
        self.fixture = fixture
        self.processes = processes
        self.master = master
        files = HostFiles(host: RemoteHost(name: "fixture", sshTarget: "fixture", socketPath: "", tmpdir: fixture.temp.path, easlBin: "easl"), master: master)
        self.server = server
        port = ports[0]
        other = ports[1]
    }

    var allow: [String] { ["127.0.0.1:\(port)"] }

    func url(_ path: String, port: Int? = nil) -> URL {
        URL(string: "http://127.0.0.1:\(port ?? self.port)\(path)")!
    }

    var clientPID: Int32? {
        (try? String(contentsOf: fixture.directory.appendingPathComponent("client.pid"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var requests: [Upstream] { records("requests.jsonl") }
    var large: Large? { (records("large.jsonl") as [Large]).first }

    private func records<T: Decodable>(_ name: String) -> [T] {
        let text = (try? String(contentsOf: fixture.directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    func fetch(_ request: HostHTTPRequest) async throws -> Fetched {
        let fetched = Locked(Fetched())
        try await files.http(request, allow: allow) { event in
            fetched.withLock { state in
                switch event {
                case .response(let head):
                    state.heads.append(head)
                case .bytes(let data):
                    state.bytesBeforeHead = state.bytesBeforeHead || state.heads.isEmpty
                    state.chunks.append(data.count)
                    state.body.append(data)
                    state.hasher.update(data: data)
                }
            }
        }
        return fetched.withLock { $0 }
    }

    func close() {
        server.terminate()
        server.waitUntilExit()
        master.close()
        processes.terminateAll(grace: 0.05)
    }

    private static let upstream = #"""
    import gzip
    import http.server
    import json
    import os
    import socketserver
    import sys
    import threading

    directory, size, large = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    body = bytes(i % 251 for i in range(size))
    text = b'compressed text\n' * 1000
    lock = threading.Lock()


    def record(name, entry):
        with lock, open(os.path.join(directory, name), 'a') as file:
            file.write(json.dumps(entry) + '\n')


    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *args):
            pass

        def do_GET(self):
            span = self.headers.get('Range')
            record('requests.jsonl', {'port': self.server.server_address[1], 'method': self.command, 'path': self.path,
                                      'headers': sorted(name.lower() for name in self.headers.keys()), 'range': span})
            if self.path == '/body' and span:
                start, end = (int(edge) for edge in span[len('bytes='):].split('-'))
                self.reply(206, [('Content-Type', 'application/octet-stream'), ('Content-Length', str(end + 1 - start)),
                                 ('Content-Range', 'bytes %d-%d/%d' % (start, end, size))], body[start:end + 1])
            elif self.path == '/body':
                self.reply(200, [('Content-Type', 'application/octet-stream'), ('Content-Length', str(size)),
                                 ('Accept-Ranges', 'bytes'), ('X-Frame-Options', 'DENY'), ('Set-Cookie', 'session=upstream'),
                                 ('Keep-Alive', 'timeout=5'), ('Connection', 'keep-alive')], body)
            elif self.path == '/missing':
                self.reply(404, [('Content-Type', 'text/plain'), ('Content-Length', '8')], b'missing\n')
            elif self.path in ('/redirect', '/away', '/loop'):
                location = {'/redirect': '/body', '/loop': '/loop',
                            '/away': 'http://127.0.0.1:%d/secret' % servers[1].server_address[1]}[self.path]
                self.reply(302, [('Location', location), ('Content-Length', '0')])
            elif self.path == '/gzip':
                data = gzip.compress(text)
                self.reply(200, [('Content-Type', 'text/plain'), ('Content-Encoding', 'gzip'), ('Content-Length', str(len(data)))], data)
            elif self.path == '/brotli':
                self.reply(200, [('Content-Type', 'text/plain'), ('Content-Encoding', 'br'), ('Content-Length', '4')], b'abcd')
            elif self.path == '/large':
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(large))
                self.end_headers()
                block, sent, outcome = b'x' * 65536, 0, 'completed'
                try:
                    while sent < large:
                        self.wfile.write(block)
                        sent += len(block)
                except OSError:
                    outcome = 'aborted'
                    self.close_connection = True
                record('large.jsonl', {'outcome': outcome, 'sent': sent})
            else:
                self.reply(404, [('Content-Length', '0')])

        do_HEAD = do_GET

        def reply(self, status, headers, data=b''):
            self.send_response(status)
            for name, value in headers:
                self.send_header(name, value)
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(data)


    # The fixture needs a loopback socket, not HTTPServer's reverse-DNS hostname lookup.
    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True


    servers = [Server(('127.0.0.1', 0), Handler) for _ in range(2)]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    ports = os.path.join(directory, 'ports')
    with open(ports + '.partial', 'w') as file:
        file.write(' '.join(str(server.server_address[1]) for server in servers))
    os.rename(ports + '.partial', ports)
    threading.Event().wait(120)
    """#
}
