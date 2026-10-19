import Foundation

public struct HostReferenceRequest: Sendable {
    public var boardRoot: String
    public var board: String
    public var tile: String
    public var merged: [String]
    public var reportedCwd: String?
    public var cwd: String?
    public var hosted: Bool
    public var candidates: [TerminalReferences.Candidate]

    public init(boardRoot: String, board: String, tile: String, merged: [String] = [], reportedCwd: String? = nil,
                cwd: String? = nil, hosted: Bool = false, candidates: [TerminalReferences.Candidate]) {
        self.boardRoot = boardRoot
        self.board = board
        self.tile = tile
        self.merged = merged
        self.reportedCwd = reportedCwd
        self.cwd = cwd
        self.hosted = hosted
        self.candidates = candidates
    }
}

public enum HostReferenceOutcome: Equatable, Sendable {
    public struct Resolved: Equatable, Sendable {
        public var candidate: Int
        public var path: String
        public var pytestBytes: Data?
    }
    public enum Failure: String, Equatable, Sendable {
        case missing, ambiguous, refused, tooLarge, unavailable, unreadable

        public var message: String {
            switch self {
            case .missing: "File not found on the host"
            case .ambiguous: "More than one host file matches this reference"
            case .refused: "File reference is outside the board or cannot be read safely"
            case .tooLarge: "Host file is too large to locate the test"
            case .unavailable: "Host file lookup is unavailable"
            case .unreadable: "Host file could not be read"
            }
        }
    }
    case resolved(Resolved)
    case failure(Failure)
}

public struct HostReferences: Sendable {
    public let files: HostFiles
    public let host: RemoteHost

    public init(files: HostFiles, host: RemoteHost) {
        self.files = files
        self.host = host
    }

    public func resolve(_ request: HostReferenceRequest) async throws -> HostReferenceOutcome {
        try await files.resolveReference(request, host: host)
    }
}

extension HostFiles {
    public func resolveReference(_ request: HostReferenceRequest, host: RemoteHost) async throws -> HostReferenceOutcome {
        struct Reading: Encodable { var path: String; var pytest: Bool }
        struct Payload: Encodable {
            var boardRoot: String; var board: String; var tile: String; var merged: [String]
            var reportedCwd: String?; var cwd: String?; var hosted: Bool
            var home: String; var zmx: String; var zmxDir: String?; var tmpdir: String
            var readings: [Reading]
        }
        struct Reply: Decodable { var ok: Bool; var candidate: Int?; var path: String?; var data: String?; var code: String? }
        let payload = Payload(boardRoot: request.boardRoot, board: request.board, tile: request.tile, merged: request.merged,
                              reportedCwd: request.reportedCwd, cwd: request.cwd, hosted: request.hosted,
                              home: HostedTerminal.homeLabel((host.socketPath as NSString).deletingLastPathComponent),
                              zmx: host.zmxBin, zmxDir: host.zmxDir, tmpdir: host.tmpdir,
                              readings: request.candidates.map { Reading(path: $0.reference.path, pytest: $0.reference.test != nil) })
        let output = try await execute(Self.referenceProgram, request: JSONEncoder().encode(payload), retryTransport: true, what: "host reference resolver")
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(output.utf8)) else { return .failure(.unavailable) }
        guard reply.ok else { return .failure(HostReferenceOutcome.Failure(rawValue: reply.code ?? "") ?? .unreadable) }
        guard let index = reply.candidate, request.candidates.indices.contains(index), let path = reply.path,
              path.hasPrefix("/") else { return .failure(.unavailable) }
        let bytes = reply.data.flatMap { Data(base64Encoded: $0) }
        if request.candidates[index].reference.test != nil, bytes == nil { return .failure(.unavailable) }
        return .resolved(.init(candidate: index, path: path, pytestBytes: bytes))
    }

    private static let referenceProgram = HostProgram(prelude + #"""
    const isDir = p => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
    function resolve() {
      const areas = boardAreas(req.boardRoot), root = areas[0].lex;
      const areaOf = p => areas.find(a => (inside(a.lex, p) || inside(a.real, p)) && inside(a.real, resolved(p)));
      const expand = p => p?.startsWith('~/') ? path.join(require('node:os').homedir(), p.slice(2)) : p;
      const directory = p => {
        if (typeof p !== 'string' || !p || p.includes('\0')) return null;
        if (p.startsWith('file:')) {
          try { p = decodeURIComponent(new URL(p).pathname); } catch { return null; }
        }
        if (!path.isAbsolute(p) || p.includes('\0')) return null;
        const abs = path.resolve(root, expand(p));
        return isDir(abs) ? abs : null;
      };
      const reported = req.hosted ? null : directory(req.reportedCwd);
      let session = null, sessionError = null;
      if (!req.hosted && !reported) {
        try {
          const env = { ...process.env, TMPDIR: req.tmpdir };
          if (req.zmxDir) env.ZMX_DIR = req.zmxDir;
          else delete env.ZMX_DIR;
          const listing = cp.execFileSync(req.zmx, ['list'], { env, encoding: 'utf8', timeout: 2000, maxBuffer: 1048576, stdio: ['ignore', 'pipe', 'pipe'] });
          for (const line of listing.split('\n')) {
            const fields = Object.fromEntries(line.replace(/^[ *→]+/, '').split('\t').map(f => { const i = f.indexOf('='); return [f.slice(0, i), f.slice(i + 1)]; }));
            if (fields.name !== 'canvas-' + req.tile || fields['canvas.tile'] !== req.tile || fields['canvas.home'] !== req.home ||
                ![req.board, ...req.merged].includes(fields['canvas.board']) || fields.err || ['cleaning up', 'unreachable'].includes(fields.status)) continue;
            session = directory(fields.cwd);
            break;
          }
        } catch { sessionError = 'unavailable'; }
      }
      const dirs = req.hosted ? [root] : [...new Set([reported, session, directory(req.cwd), root].filter(Boolean))];
      const near = resolved(dirs[0]);
      const roots = areas.map(a => a.real);
      const candidate = p => {
        const area = areaOf(p);
        if (!area) return null;
        const prefix = inside(area.lex, p) ? area.lex : area.real;
        const base = area.real === areas[0].real ? root : area.real;
        return { path: path.join(base, path.relative(prefix, p)), canonical: resolved(p) };
      };
      const readRequest = (found, bytes = false) => ({
        path: found.canonical, roots, bytes, limit: \#(SourceExcerpt.maxFileBytes), metadataLimit: false
      });
      const inspect = (p, bytes = false) => {
        const found = candidate(p);
        if (!found) fail('refused');
        const reply = readFiles([readRequest(found, bytes)])[0];
        if (!reply.ok && reply.code !== 'not_found') fail(reply.code === 'too_large' ? 'tooLarge' : reply.code);
        return reply.ok ? { ...found, ...(bytes ? { data: reply.data } : {}) } : null;
      };
      let index = null;
      function listed() {
        if (index !== null) return index;
        index = [];
        const output = git(root, ['ls-files', '--cached', '--others', '--exclude-standard', '--deduplicate', '-z'], 64 * 1024 * 1024);
        if (output) {
          for (const relative of output.toString('utf8').split('\0').filter(Boolean).slice(0, 200000)) {
            index.push({ relative, absolute: path.resolve(root, relative) });
          }
        }
        return index;
      }
      const distance = p => {
        const here = near.split('/'), there = path.dirname(p).split('/');
        let common = 0;
        while (common < Math.min(here.length, there.length) && here[common] === there[common]) common++;
        return here.length + there.length - 2 * common;
      };
      let ambiguous = false, lookupFailure = null;
      for (let i = 0; i < req.readings.length; i++) {
        const reading = req.readings[i], input = reading.path;
        if (typeof input !== 'string' || !input || input.includes('\0')) fail('refused');
        let winner = null;
        if (path.isAbsolute(input) || input.startsWith('~')) {
          if (input.startsWith('~') && !input.startsWith('~/')) fail('refused');
          winner = inspect(path.resolve(expand(input)));
        } else {
          if (sessionError) { lookupFailure = sessionError; continue; }
          const relatives = [input];
          if (/^[ab]\//.test(input)) relatives.push(input.slice(2));
          for (const relative of relatives) {
            for (const dir of dirs) {
              winner = inspect(path.resolve(dir, relative));
              if (winner) break;
            }
            if (winner) break;
          }
          if (!winner && !input.split('/').includes('..')) {
            for (const relative of relatives) {
              const suffix = relative.replace(/^(\.\/)+/, '');
              const matches = new Map();
              const pending = [];
              for (const entry of listed()) {
                if (entry.relative !== suffix && !entry.relative.endsWith('/' + suffix)) continue;
                const found = candidate(entry.absolute);
                if (found) pending.push(found);
                else lookupFailure = 'refused';
              }
              const replies = readFiles(pending.map(found => readRequest(found)));
              for (let j = 0; j < pending.length; j++) {
                const reply = replies[j], found = pending[j];
                if (reply.ok) matches.set(found.canonical, found);
                else if (reply.code !== 'not_found' && lookupFailure !== 'refused') lookupFailure = reply.code === 'too_large' ? 'tooLarge' : reply.code;
              }
              const ranked = [...matches.values()].sort((a, b) => distance(a.canonical) - distance(b.canonical));
              if (!ranked.length) continue;
              if (ranked.length === 1 || distance(ranked[0].canonical) < distance(ranked[1].canonical)) winner = ranked[0];
              else ambiguous = true;
              break;
            }
          }
        }
        if (winner) {
          if (reading.pytest) winner = inspect(winner.path, true);
          if (winner) return { ok: true, candidate: i, path: winner.path, ...(reading.pytest ? { data: winner.data } : {}) };
        }
      }
      return { ok: false, code: lookupFailure || (ambiguous ? 'ambiguous' : 'missing') };
    }
    let reply;
    try { reply = resolve(); }
    catch (e) { reply = { ok: false, code: e.code === 'too_large' ? 'tooLarge' : e.code || 'unreadable' }; }
    process.stdout.write(JSON.stringify(reply));
    """#)
}
