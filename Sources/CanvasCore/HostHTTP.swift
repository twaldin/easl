import Darwin
import Foundation

public struct HostHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var range: String?

    public init(url: URL, method: String = "GET", range: String? = nil) {
        self.url = url
        self.method = method
        self.range = range
    }
}

/// The upstream response after redirects. Header names are lowercase. Hop-by-hop headers,
/// Set-Cookie, and the Content-Encoding and Content-Length of a body the host decoded are gone.
public struct HostHTTPHead: Sendable {
    public var url: URL
    public var status: Int
    public var headers: [String: String]
}

public enum HostHTTPEvent: Sendable {
    case response(HostHTTPHead)
    case bytes(Data)
}

extension HostFiles {
    /// Fetches `request` on the host with Python's standard-library HTTP client: no proxy,
    /// cookies or credentials, only the range forwarded. Redirects must stay same-origin and
    /// match `allow`. `receive` gets the head, then body chunks of at most 64 KiB; the host is
    /// read for the next chunk only after `receive` returns.
    public func http(_ request: HostHTTPRequest, allow: [String], receive: @escaping @Sendable (HostHTTPEvent) async throws -> Void) async throws {
        let rules = HostNetworkPolicy.rules(allow: allow)
        guard HostHTTP.methods.contains(request.method), HostNetworkPolicy.permits(request.url, rules: rules),
              request.range.map(HostHTTP.isRange) ?? true else { throw HostFileError.refused }
        let payload = HostHTTP.Payload(url: request.url.absoluteString, method: request.method, range: request.range, rules: rules)
        let input = try JSONEncoder().encode(payload)
        try await httpSession { route in
            let command = invocation(HostHTTP.program, request: input, route: route)
            let client = HostHTTPClient(command)
            try await withTaskCancellationHandler {
                try await client.run(initialURL: request.url, rules: rules, receive: receive)
            } onCancel: {
                client.cancel()
            }
        }
    }
}

enum HostHTTP {
    static let chunk = 64 * 1024
    static let maxHead = 64 * 1024
    static let redirects = 10
    static let idleSeconds = 30
    static let methods: Set<String> = ["GET", "HEAD"]
    static let invalid = HostFileError.unavailable("invalid host HTTP reply")

    static func isRange(_ value: String) -> Bool {
        value.utf8.count <= 256
            && value.range(of: #"\Abytes=[0-9]*-[0-9]*(,[ \t]*[0-9]*-[0-9]*)*\z"#, options: .regularExpression) != nil
    }

    struct Payload: Encodable {
        let kind = "http"
        var url: String
        var method: String
        var range: String?
        var rules: [HostNetworkRule]
    }

    struct Head: Decodable {
        var ok: Bool
        var status: Int?
        var url: String?
        var headers: [String: String]?
        var code: String?
        var message: String?
        var limit: Int?
    }

    static let program = HostProgram(#"""
    const python = String.raw`
    import http.client
    import json
    import os
    import re
    import socket
    import ssl
    import string
    import sys
    import urllib.parse
    import zlib

    CHUNK = \#(chunk)
    HEAD = \#(maxHead)
    IDLE = \#(idleSeconds)
    REDIRECTS = \#(redirects)
    SKIPPED = ('connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'proxy-connection', 'te',
               'trailer', 'trailers', 'transfer-encoding', 'upgrade', 'set-cookie', 'set-cookie2')
    AUTHORITY = re.compile(r'(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?\Z')
    LABEL = re.compile(r'(?!-)[a-z0-9-]{1,63}(?<!-)\Z')
    FOLD = re.compile(r'[\r\n]+[ \t]*')


    class Refused(Exception):
        pass


    class TooLarge(Exception):
        pass


    def send(data):
        view = memoryview(data)
        while view:
            view = view[os.write(1, view):]


    def ipv6(literal):
        try:
            packed = socket.inet_pton(socket.AF_INET6, literal)
        except (OSError, ValueError):
            return None
        words = ['%x' % (packed[i] << 8 | packed[i + 1]) for i in range(0, 16, 2)]
        start = length = index = 0
        while index < 8:
            first = index
            while index < 8 and words[index] == '0':
                index += 1
            if index - first > length:
                start, length = first, index - first
            index += 1
        if length < 2:
            return '[' + ':'.join(words) + ']'
        return '[' + ':'.join(words[:start]) + '::' + ':'.join(words[start + length:]) + ']'


    def destination(url, rules):
        try:
            parts = urllib.parse.urlsplit(url)
        except ValueError:
            raise Refused()
        match = AUTHORITY.match(parts.netloc.lower())
        if parts.scheme not in ('http', 'https') or not match:
            raise Refused()
        host = match.group(1)
        if host.startswith('['):
            host = ipv6(host[1:-1])
        elif len(host) > 253 or not all(LABEL.match(label) for label in host.split('.')):
            host = None
        port = int(match.group(2) or (443 if parts.scheme == 'https' else 80))
        if host is None or not 0 < port < 65536 or not any(
                rule.get('port') in (None, port)
                and (host == rule['host'] or (rule['subdomains'] and host.endswith('.' + rule['host'])))
                for rule in rules):
            raise Refused()
        return parts, host, port


    def fetch(method, url, span, rules):
        origin = None
        for _ in range(REDIRECTS + 1):
            parts, host, port = destination(url, rules)
            current = parts.scheme, host, port
            if origin is None:
                origin = current
            elif current != origin:
                raise Refused()
            if parts.scheme == 'https':
                connection = http.client.HTTPSConnection(host, port, timeout=IDLE, context=ssl.create_default_context())
            else:
                connection = http.client.HTTPConnection(host, port, timeout=IDLE)
            connection.putrequest(method, (parts.path or '/') + ('?' + parts.query if parts.query else ''))
            if span is not None:
                connection.putheader('Range', span)
            connection.endheaders()
            response = connection.getresponse()
            location = response.getheader('Location')
            if response.status not in (301, 302, 303, 307, 308) or location is None:
                return urllib.parse.urlunsplit(parts._replace(fragment='')), response
            connection.close()
            url = urllib.parse.urljoin(url, urllib.parse.quote(location.strip(), safe=string.punctuation, encoding='iso-8859-1'))
        raise RuntimeError('too many redirects')


    def head(final, response):
        skipped = set(SKIPPED)
        for value in response.msg.get_all('Connection') or ():
            skipped.update(token.strip().lower() for token in value.split(','))
        codings = [token.strip().lower() for value in response.msg.get_all('Content-Encoding') or () for token in value.split(',')]
        codings = [token for token in codings if token not in ('', 'identity')]
        decoder = None
        if codings:
            if codings not in (['gzip'], ['x-gzip'], ['deflate']):
                raise RuntimeError('unsupported content encoding ' + ', '.join(codings))
            if response.status == 206:
                raise RuntimeError('a partial response with content encoding ' + codings[0])
            skipped.update(('content-encoding', 'content-length'))
            decoder = zlib.decompressobj(47)
        headers = {}
        for name, value in response.getheaders():
            key, value = name.lower(), FOLD.sub(' ', value)
            if key not in skipped:
                headers[key] = headers[key] + ', ' + value if key in headers else value
        line = json.dumps({'ok': True, 'status': response.status, 'url': final, 'headers': headers}).encode() + b'\n'
        if len(line) > HEAD:
            raise TooLarge()
        return line, decoder


    def body(response, decoder):
        while True:
            data = response.read1(CHUNK)
            if not data:
                break
            if decoder is None:
                yield data
                continue
            while data:
                if decoder.eof:
                    raise RuntimeError('data after the end of the encoded body')
                yield decoder.decompress(data, CHUNK)
                data = decoder.unconsumed_tail
        if response.length:
            raise http.client.IncompleteRead(b'', response.length)
        if decoder is not None:
            yield decoder.flush()
            if not decoder.eof or decoder.unused_data:
                raise RuntimeError('the encoded body is incomplete')


    def main():
        os.set_blocking(1, True)
        request = json.loads(sys.stdin.buffer.read())
        answered = False
        try:
            final, response = fetch(request['method'], request['url'], request.get('range'), request['rules'])
            line, decoder = head(final, response)
            send(line)
            answered = True
            if request['method'] != 'HEAD':
                for piece in body(response, decoder):
                    view = memoryview(piece)
                    for start in range(0, len(view), CHUNK):
                        send(view[start:start + CHUNK])
        except BrokenPipeError:
            os._exit(1)
        except Exception as error:
            message = (str(error) or type(error).__name__)[:1000]
            if answered:
                try:
                    os.write(2, ('host HTTP failed: ' + message + '\n').encode())
                finally:
                    os._exit(1)
            if isinstance(error, Refused):
                reply = {'ok': False, 'code': 'refused'}
            elif isinstance(error, TooLarge):
                reply = {'ok': False, 'code': 'too_large', 'limit': HEAD}
            else:
                reply = {'ok': False, 'code': 'unavailable', 'message': message}
            send(json.dumps(reply).encode() + b'\n')


    main()
    `;
    const run = require('node:child_process').spawnSync('python3', ['-I', '-S', '-B', '-c', python], {
      input: JSON.stringify(req), stdio: ['pipe', 'inherit', 'inherit']
    });
    if (run.error) {
      process.stderr.write(run.error.code === 'ENOENT'
        ? 'python3 is required for host HTTP but is not installed on the host\n'
        : 'python3 host HTTP client failed: ' + run.error.message + '\n');
    }
    process.exitCode = run.error ? 127 : run.status ?? 1;
    """#)
}

private final class HostHTTPClient: @unchecked Sendable {
    private let command: (executable: String, arguments: [String], input: Data)
    private let process = Process()
    private let output = Pipe(), errors = Pipe(), input = Pipe()
    private let exited = DispatchGroup(), written = DispatchGroup()
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: HostHTTP.chunk, alignment: 1)
    private var polls = [pollfd](repeating: pollfd(), count: 2)
    private var errorsOpen = true
    private var errorTail = Data()

    init(_ command: (executable: String, arguments: [String], input: Data)) {
        self.command = command
    }

    deinit { buffer.deallocate() }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock {
            cancelled = true
            if started { RemoteProcesses.stop(process) }
        }
    }

    func run(initialURL: URL, rules: [HostNetworkRule], receive: @Sendable (HostHTTPEvent) async throws -> Void) async throws {
        try start()
        var failure: (any Error)?
        var responded = false
        do {
            responded = try await pump(initialURL: initialURL, rules: rules, receive: receive)
        } catch {
            failure = error
        }
        let ending = failure != nil
        let status = await offPool { self.finish(ending: ending) }
        if isCancelled { throw CancellationError() }
        if let failure { throw failure }
        guard status == 0 else {
            throw HostFileError.unavailable(RemoteHost.lastLine(String(decoding: errorTail, as: UTF8.self)) ?? "host HTTP exited with status \(status)")
        }
        guard responded else { throw HostHTTP.invalid }
    }

    private func start() throws {
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let exited = self.exited
        process.terminationHandler = { _ in exited.leave() }
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            exited.enter()
            do {
                try RemoteProcesses.shared.launch(process)
            } catch {
                exited.leave()
                throw HostFileError.unavailable("cannot run \(command.executable): \(error.localizedDescription)")
            }
            started = true
        }
        try? input.fileHandleForReading.close()
        let writer = input.fileHandleForWriting, bytes = command.input, written = self.written
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        written.enter()
        DispatchQueue.global().async {
            try? writer.write(contentsOf: bytes)
            try? writer.close()
            written.leave()
        }
    }

    private func pump(initialURL: URL, rules: [HostNetworkRule], receive: @Sendable (HostHTTPEvent) async throws -> Void) async throws -> Bool {
        guard let first = try await headLine() else { return false }
        guard let head = try? JSONDecoder().decode(HostHTTP.Head.self, from: first.line) else { throw HostHTTP.invalid }
        guard head.ok else { throw HostFileError(code: head.code, message: head.message, limit: head.limit) }
        guard let status = head.status, (100...599).contains(status), let url = head.url.flatMap({ URL(string: $0) }),
              HostNetworkPolicy.sameOrigin(url, initialURL), HostNetworkPolicy.permits(url, rules: rules),
              let headers = head.headers else { throw HostHTTP.invalid }
        try await receive(.response(HostHTTPHead(url: url, status: status, headers: headers)))
        if !first.rest.isEmpty {
            try Task.checkCancellation()
            try await receive(.bytes(first.rest))
        }
        while true {
            let chunk = try await next()
            if chunk.isEmpty { return true }
            try Task.checkCancellation()
            try await receive(.bytes(chunk))
        }
    }

    private func headLine() async throws -> (line: Data, rest: Data)? {
        var pending = Data()
        while true {
            let chunk = try await next()
            if chunk.isEmpty { return nil }
            pending.append(chunk)
            let newline = pending[(pending.count - chunk.count)...].firstIndex(of: 0x0a)
            guard (newline ?? pending.count) < HostHTTP.maxHead else { throw HostHTTP.invalid }
            if let newline { return (pending[..<newline], Data(pending[(newline + 1)...])) }
        }
    }

    private func next() async throws -> Data {
        try await offPool { Result { try self.read() } }.get()
    }

    private func read() throws -> Data {
        let fd = output.fileHandleForReading.fileDescriptor
        while true {
            if isCancelled { throw CancellationError() }
            polls[0] = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            polls[1] = pollfd(fd: errorsOpen ? errors.fileHandleForReading.fileDescriptor : -1, events: Int16(POLLIN), revents: 0)
            guard poll(&polls, 2, 100) >= 0 else {
                if errno == EINTR { continue }
                throw HostFileError.unavailable("host HTTP output failed")
            }
            if polls[1].revents != 0 { drainErrors() }
            guard polls[0].revents != 0 else { continue }
            let count = Darwin.read(fd, buffer.baseAddress, buffer.count)
            if count >= 0 { return Data(bytes: buffer.baseAddress!, count: count) }
            if errno != EINTR && errno != EAGAIN { throw HostFileError.unavailable("host HTTP output failed") }
        }
    }

    private func drainErrors() {
        let count = Darwin.read(errors.fileHandleForReading.fileDescriptor, buffer.baseAddress, buffer.count)
        if count > 0 {
            errorTail.append(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
            if errorTail.count > 8192 { errorTail.removeFirst(errorTail.count - 8192) }
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
            errorsOpen = false
        }
    }

    private func finish(ending: Bool) -> Int32 {
        if ending { RemoteProcesses.stop(process) }
        try? output.fileHandleForReading.close()
        while errorsOpen, !ending {
            if isCancelled {
                RemoteProcesses.stop(process)
                break
            }
            var polled = pollfd(fd: errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&polled, 1, 100)
            if ready > 0 {
                drainErrors()
            } else if ready < 0 && errno != EINTR {
                break
            }
        }
        exited.wait()
        written.wait()
        try? errors.fileHandleForReading.close()
        return process.terminationStatus
    }
}
