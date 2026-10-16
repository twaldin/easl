import Foundation

public struct HostFileRequest: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case directory(String)
        case liveRoot(ref: String, boardRoot: String)
        case ref(String, lastKnownSha: String?, boardRoot: String)
    }

    public enum Policy: Sendable, Equatable {
        case boardFile(String)
        case pageImage(relative: String?, absolute: String?, temps: [String])
    }

    public var source: Source
    public var policy: Policy
    public var bytes: Bool

    public init(source: Source, policy: Policy, bytes: Bool = true) {
        self.source = source
        self.policy = policy
        self.bytes = bytes
    }
}

public struct HostFile: Sendable, Equatable {
    public var root: String
    public var path: String?
    public var commit: String?
    public var data: Data
    public var mimeType: String { HtmlKit.mimeType(URL(fileURLWithPath: path ?? "")) }
}

public enum HostFileError: Error, Equatable, Sendable {
    case refused
    case notFound(commit: String?)
    case tooLarge(limit: Int)
    case unreadable
    case ref(String)
    case unavailable(String)
}

public struct HostFiles: Sendable {
    public let hostName: String
    public let temps: [String]
    private let route: HostRoute
    private let master: HostMaster?

    public init(host: RemoteHost, master: HostMaster) {
        hostName = host.name
        temps = [host.tmpdir, "/tmp", "/var/tmp"]
        route = master.route
        self.master = master
    }

    init(hostName: String, route: HostRoute, temps: [String]) {
        self.hostName = hostName
        self.route = route
        self.temps = temps
        master = nil
    }

    public func read(_ request: HostFileRequest) async throws -> HostFile {
        let payload = try payload(request)
        do {
            if let master {
                try await master.ready()
                try await master.fileSession()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HostFileError.unavailable(String(describing: error))
        }
        let result: (status: Int32, output: String, errors: String)
        do {
            result = try await RemoteHost.run(route.executable, route.ssh(HostedTerminal.remote(Self.launcher, [Self.script, payload])), timeout: 20)
        } catch {
            if let master { await master.endFileSession() }
            throw error
        }
        if let master { await master.endFileSession() }
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw HostFileError.unavailable(RemoteHost.lastLine(result.errors) ?? "host file reader exited with status \(result.status)")
        }
        guard let data = result.output.data(using: .utf8), let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw HostFileError.unavailable("invalid host file reply")
        }
        guard reply.ok else {
            switch reply.code {
            case "refused": throw HostFileError.refused
            case "not_found": throw HostFileError.notFound(commit: reply.commit)
            case "too_large": throw HostFileError.tooLarge(limit: reply.limit ?? SourceExcerpt.maxFileBytes)
            case "unreadable": throw HostFileError.unreadable
            case "ref": throw HostFileError.ref(reply.message ?? "unknown ref")
            default: throw HostFileError.unavailable(reply.message ?? "host file read failed")
            }
        }
        guard let root = reply.root, let encoded = reply.data, let bytes = Data(base64Encoded: encoded) else {
            throw HostFileError.unavailable("invalid host file bytes")
        }
        return HostFile(root: root, path: reply.path, commit: reply.commit, data: bytes)
    }

    private struct Reply: Decodable {
        var ok: Bool
        var root: String?
        var path: String?
        var commit: String?
        var data: String?
        var code: String?
        var message: String?
        var limit: Int?
    }

    private func payload(_ request: HostFileRequest) throws -> String {
        var source: [String: JSONValue]
        switch request.source {
        case .directory(let root): source = ["kind": .string("directory"), "root": .string(root)]
        case .liveRoot(let ref, let root): source = ["kind": .string("live"), "root": .string(root), "ref": .string(ref)]
        case .ref(let ref, let sha, let root):
            source = ["kind": .string("ref"), "root": .string(root), "ref": .string(ref)]
            if let sha, NoteSource.isRevision(sha) { source["sha"] = .string(sha) }
        }
        if let ref = source["ref"]?.string, !NoteSource.isRevision(ref) {
            if source["kind"] == .string("live") { source = ["kind": .string("directory"), "root": source["root"]!] }
            else { throw HostFileError.ref("\"\(ref)\" is not a ref") }
        }
        let policy: JSONValue
        switch request.policy {
        case .boardFile(let relative):
            policy = .object(["kind": .string("board"), "relative": .string(try HtmlKit.boardRelative(relative))])
        case .pageImage(let relative, let absolute, let temps):
            policy = .object(["kind": .string("image"), "relative": relative.map(JSONValue.string) ?? .null,
                              "absolute": absolute.map(JSONValue.string) ?? .null, "temps": .array(temps.map(JSONValue.string))])
        }
        let value = JSONValue.object(["source": .object(source), "policy": policy, "bytes": .bool(request.bytes)])
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static let launcher = #"""
    for b in "$(command -v bun)" "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
      if [ -n "$b" ] && [ -x "$b" ]; then exec "$b" -e "$1" -- "$2"; fi
    done
    echo "bun isn't installed on the host" >&2
    exit 127
    """#

    private static let script = #"""
    const fs = require('node:fs');
    const path = require('node:path');
    const cp = require('node:child_process');
    const req = JSON.parse(process.argv.at(-1));
    const source = req.source, policy = req.policy;
    const fail = (code, extra = {}) => { throw { code, ...extra }; };
    const real = p => { try { return fs.realpathSync(p); } catch { return null; } };
    const resolved = p => {
      const found = real(p);
      if (found) return found;
      const parent = path.dirname(p);
      return parent === p ? p : path.join(resolved(parent), path.basename(p));
    };
    const inside = (dir, p) => dir === '/' || p === dir || p.startsWith(dir + '/');
    const git = (dir, args, max = 1048576) => {
      try {
        return cp.execFileSync('git', ['-C', dir, ...args], {
          env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_LAZY_FETCH: '1' },
          timeout: 20000, maxBuffer: max, stdio: ['ignore', 'pipe', 'pipe']
        });
      } catch (e) {
        if (e.code === 'ENOENT' || e.code === 'ETIMEDOUT') fail('unavailable', { message: 'git is unavailable' });
        if (e.code === 'ENOBUFS') fail('too_large', { limit: max });
        return null;
      }
    };
    const text = (dir, args) => git(dir, args)?.toString('utf8').trim() || null;
    const commitOf = (dir, ref) => text(dir, ['rev-parse', '--verify', '--quiet', '--end-of-options', ref + '^{commit}']);
    function resolveSource() {
      const root = path.resolve(source.root);
      if (source.kind === 'directory') return { root };
      const top = text(root, ['rev-parse', '--show-toplevel']);
      if (!top) {
        if (source.kind === 'live') return { root };
        fail('ref', { message: 'not in a git repository' });
      }
      const place = path.relative(real(top) || top, real(root) || root);
      const branch = source.ref.replace(/^refs\/heads\//, '');
      const listing = text(top, ['worktree', 'list', '--porcelain', '-z']) || '';
      for (const block of listing.split('\0\0')) {
        const lines = block.split('\0');
        const entry = lines.find(l => l.startsWith('worktree '))?.slice(9);
        if (!entry || lines.some(l => l.startsWith('prunable')) || !real(entry)) continue;
        if (!lines.includes('branch refs/heads/' + branch)) continue;
        if (source.kind === 'live' || commitOf(entry, 'HEAD')) return { root: path.join(entry, place) };
      }
      if (source.kind === 'live') return { root };
      let commit = commitOf(top, source.ref);
      if (commit) return { root, commit };
      commit = source.sha && commitOf(top, source.sha);
      if (!commit) fail('ref', { message: 'unknown ref ' + source.ref });
      let branchName = text(top, ['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD'])?.replace(/^refs\/remotes\//, '');
      if (!branchName) {
        for (const name of ['main', 'master']) {
          if (git(top, ['show-ref', '--verify', '--quiet', 'refs/heads/' + name]) !== null) { branchName = name; break; }
        }
      }
      const tip = branchName && commitOf(top, branchName);
      if (tip && git(top, ['merge-base', '--is-ancestor', commit, tip]) !== null && commit !== tip) {
        const first = text(top, ['rev-list', '--first-parent', '--ancestry-path', '--reverse', '--parents', commit + '..' + tip])?.split('\n')[0]?.split(' ');
        if (first?.length && first[1] !== commit) commit = first[0];
      }
      return { root, commit };
    }
    function readRegular(p, root, limit) {
      let fd;
      try {
        fd = fs.openSync(p, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
        const st = fs.fstatSync(fd);
        if (!st.isFile()) fail('not_found');
        if (!req.bytes) return { ok: true, root, path: p, data: '' };
        if (limit != null && st.size > limit) fail('too_large', { limit });
        const data = fs.readFileSync(fd);
        if (limit != null && data.length > limit) fail('too_large', { limit });
        return { ok: true, root, path: p, data: data.toString('base64') };
      } catch (e) {
        if (e.code && !['ENOENT', 'ENOTDIR', 'ELOOP', 'EACCES', 'EPERM'].includes(e.code)) throw e;
        fail(['ENOENT', 'ENOTDIR'].includes(e.code) ? 'not_found' : 'unreadable');
      } finally { if (fd !== undefined) fs.closeSync(fd); }
    }
    function read() {
      const { root, commit } = resolveSource();
      if (policy.kind === 'board') {
        const rel = policy.relative;
        if (!rel || rel.includes('\0') || rel.startsWith('/') || rel.startsWith('~') || rel.split('/').includes('..')) fail('refused');
        const base = resolved(root), candidate = resolved(path.join(root, rel));
        if (!candidate.startsWith(base + '/')) fail('refused');
        if (commit) {
          if (!req.bytes) return { ok: true, root, commit, data: '' };
          const data = git(root, ['show', '--end-of-options', commit + ':./' + rel], 33554432);
          if (data === null) fail('not_found', { commit });
          return { ok: true, root, commit, data: data.toString('base64') };
        }
        const p = real(candidate);
        if (!p) fail('not_found');
        return readRegular(p, root, 4194304);
      }
      const extensions = new Set(['png','jpg','jpeg','gif','webp','heic','heif','tif','tiff','bmp','svg','pdf']);
      const dirs = [root, ...policy.temps].map(d => real(d) || path.resolve(d));
      const allowed = p => p && extensions.has(path.extname(p).slice(1).toLowerCase()) && dirs.some(d => inside(d, p));
      if (policy.relative != null) {
        const p = real(path.resolve(root, policy.relative));
        if (allowed(p)) return readRegular(p, root, null);
      }
      if (policy.absolute == null) fail('refused');
      const p = real(policy.absolute);
      if (!p) fail('not_found');
      if (!allowed(p)) fail('refused');
      return readRegular(p, root, null);
    }
    let reply;
    try { reply = read(); }
    catch (e) { reply = { ok: false, code: e.code || 'unreadable', message: e.message, commit: e.commit, limit: e.limit }; }
    process.stdout.write(JSON.stringify(reply));
    """#
}
