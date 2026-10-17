import Foundation

public struct HostNoteRequest: Sendable {
    public var boardRoot: String
    public var source: HostFileRequest.Source
    public var imagesSource: HostFileRequest.Source
    public var fences: [NoteMarkdown.AnchoredFence]
    public var images: [String]

    public init(boardRoot: String, source: HostFileRequest.Source, imagesSource: HostFileRequest.Source, fences: [NoteMarkdown.AnchoredFence], images: [String] = []) {
        self.boardRoot = boardRoot
        self.source = source
        self.imagesSource = imagesSource
        self.fences = fences
        self.images = images
    }
}

public struct HostNoteObservation: Equatable, Sendable {
    public var fences: [[HostFileObservation]]
    public var images: [HostFileObservation]

    public var isUnavailable: Bool {
        var observed = false
        for candidates in fences {
            for observation in candidates {
                guard case .failure(.unavailable) = observation else { return false }
                observed = true
            }
        }
        for observation in images {
            guard case .failure(.unavailable) = observation else { return false }
            observed = true
        }
        return observed
    }
}

public struct HostNoteRead: Sendable {
    public var excerpts: [String: NoteExcerpt]
    public var images: [String: Data]
    public var observation: HostNoteObservation
}

extension HostFiles {
    public func loadNote(_ request: HostNoteRequest, captured: [String: [String]] = [:], bytes: Bool = true) async -> HostNoteRead {
        do {
            return try await note(request, captured: captured, bytes: bytes)
        } catch {
            let failure = (error as? HostFileError) ?? .unavailable(String(describing: error))
            let excerpts = Dictionary(uniqueKeysWithValues: request.fences.map {
                ($0.key, NoteExcerpt(path: $0.fence.path ?? "", range: nil, lines: captured[$0.key] ?? [], status: .stale(HostGit.refusal(failure))))
            })
            return HostNoteRead(excerpts: excerpts, images: [:], observation: HostNoteObservation(
                fences: request.fences.map { _ in [.failure(failure)] }, images: request.images.map { _ in .failure(failure) }))
        }
    }

    public func note(_ request: HostNoteRequest, captured: [String: [String]] = [:], bytes: Bool = true) async throws -> HostNoteRead {
        guard !request.fences.isEmpty || !request.images.isEmpty else {
            return HostNoteRead(excerpts: [:], images: [:], observation: HostNoteObservation(fences: [], images: []))
        }
        let fences = request.fences.map { item -> JSONValue in
            var value: [String: JSONValue] = ["path": item.fence.path.map(JSONValue.string) ?? .null,
                                            "symbol": item.fence.symbol.map(JSONValue.string) ?? .null,
                                            "commit": item.fence.commit.map(JSONValue.string) ?? .null]
            value["validCommit"] = .bool(item.fence.commit.map(NoteSource.isRevision) ?? true)
            if let symbol = item.fence.symbol, let pattern = NoteSource.symbolPattern(symbol) {
                value["pattern"] = .string(pattern)
            }
            return .object(value)
        }
        let payload = JSONValue.object(["boardRoot": .string(request.boardRoot), "source": .object(try sourcePayload(request.source)),
                                        "imagesSource": .object(try sourcePayload(request.imagesSource)),
                                        "fences": .array(fences), "images": .array(request.images.map(JSONValue.string)),
                                        "temps": .array(temps.map(JSONValue.string)), "bytes": .bool(bytes)])
        let output = try await execute(Self.noteProgram, request: JSONEncoder().encode(payload), what: "host note reader")
        guard let reply = try? JSONDecoder().decode(NoteReply.self, from: Data(output.utf8)),
              reply.fences.count == request.fences.count, reply.images.count == request.images.count else {
            throw HostFileError.unavailable("invalid host note reply")
        }
        var excerpts: [String: NoteExcerpt] = [:]
        var images: [String: Data] = [:]
        for (item, candidates) in zip(request.fences, reply.fences) {
            guard bytes else { continue }
            let capture = captured[item.key]
            var found: NoteExcerpt?
            for candidate in candidates where candidate.ok {
                guard let data = candidate.data.flatMap({ Data(base64Encoded: $0) }), let text = String(data: data, encoding: .utf8) else { continue }
                if item.fence.path == nil, let symbol = item.fence.symbol,
                   NoteAnchor.symbolRange(symbol, in: NoteSource.lines(of: text)) == nil { continue }
                found = NoteSource.interpret(text, for: item.fence, path: item.fence.path ?? candidate.path ?? "", captured: capture, body: item.body)
                break
            }
            if let found { excerpts[item.key] = found }
            else {
                let failure = candidates.first(where: { !$0.ok })
                let reason = failure.map { HostGit.refusal($0.error) } ?? (item.fence.path == nil ? "symbol \(item.fence.symbol ?? "") not found in the workspace" : "cannot read \(item.fence.path ?? "")")
                excerpts[item.key] = NoteExcerpt(path: item.fence.path ?? "", range: nil, lines: capture ?? [], status: .stale(reason), missing: failure?.code == "not_found")
            }
        }
        if bytes {
            for (source, image) in zip(request.images, reply.images) where image.ok {
                if let data = image.data.flatMap({ Data(base64Encoded: $0) }) { images[source] = data }
            }
        }
        return HostNoteRead(excerpts: excerpts, images: images,
                            observation: HostNoteObservation(fences: reply.fences.map { $0.map(\.observation) }, images: reply.images.map(\.observation)))
    }

    private struct NoteReply: Decodable {
        var fences: [[NoteFileReply]]
        var images: [NoteFileReply]
    }

    private struct NoteFileReply: Decodable {
        var ok: Bool
        var root: String?
        var path: String?
        var commit: String?
        var stamp: String?
        var data: String?
        var code: String?
        var message: String?
        var limit: Int?
        var error: HostFileError { HostFileError(code: code, message: message, commit: commit, limit: limit) }
        var observation: HostFileObservation {
            ok ? .version(HostFileVersion(root: root ?? "", path: path, commit: commit, stamp: stamp)) : .failure(error)
        }
    }

    private static let noteProgram = HostProgram(prelude + #"""
    const limit = \#(SourceExcerpt.maxFileBytes);
    let remaining = \#(NoteSource.maxOutput);
    const areas = boardAreas(req.boardRoot);
    const areaOf = p => areas.find(a => (inside(a.lex, p) || inside(a.real, p)) && inside(a.real, resolved(p)));
    const writtenAreaOf = p => areas.find(a => inside(a.lex, p) || inside(a.real, p));
    const selectedSources = new Map();
    function noteSource(input) {
      let selected = selectedSources.get(input);
      if (!selected) {
        selected = resolveSource(input);
        if (!areaOf(selected.root)) fail('refused');
        selectedSources.set(input, selected);
      }
      return selected;
    }
    const protect = fn => { try { return fn(); } catch (e) { return { ok: false, code: e.code || 'unreadable', message: e.message, commit: e.commit, limit: e.limit }; } };
    function noteFile(source, input) {
      if (typeof input !== 'string' || !input || input.includes('\0') || input.startsWith('~')) fail('refused');
      const root = source.root, requested = path.resolve(root, input);
      const area = source.commit ? writtenAreaOf(requested) : areaOf(requested);
      if (!area) fail('refused');
      const effectiveLimit = Math.min(limit, remaining);
      if (source.commit) {
        const directory = area.real;
        const prefix = inside(area.lex, requested) ? area.lex : area.real;
        const relative = path.relative(prefix, requested);
        const object = source.commit + ':./' + relative;
        const entry = text(directory, ['--literal-pathspecs', 'ls-tree', '-z', source.commit, '--', relative]);
        if (!entry) fail('not_found', { commit: source.commit });
        if (entry.startsWith('120000 ')) fail('refused');
        if (!/^100(644|755) /.test(entry)) fail('not_found', { commit: source.commit });
        const size = text(directory, ['cat-file', '-s', object]);
        if (size === null) fail('not_found', { commit: source.commit });
        if (Number(size) > effectiveLimit) fail('too_large', { limit: effectiveLimit });
        const data = req.bytes ? git(directory, ['show', '--end-of-options', object], effectiveLimit) : Buffer.alloc(0);
        if (data === null) fail('not_found', { commit: source.commit });
        if (data.length > effectiveLimit) fail('too_large', { limit: effectiveLimit });
        remaining -= req.bytes ? data.length : Number(size);
        return { ok: true, root, path: requested, commit: source.commit, data: data.toString('base64') };
      }
      const candidate = resolved(requested);
      const reply = readFiles([{ path: candidate, roots: [area.real], bytes: req.bytes, limit: effectiveLimit, metadataLimit: true }])[0];
      if (reply.ok) remaining -= reply.size;
      return { root, ...reply, ...(reply.ok ? { path: requested } : {}) };
    }
    function fence(item) {
      const selected = noteSource(item.commit != null ? req.imagesSource : req.source);
      let source = selected;
      if (item.commit != null) {
        if (!item.validCommit) fail('ref', { message: '"' + item.commit + '" is not a commit' });
        const commit = commitOf(selected.root, item.commit);
        if (!commit) fail('not_found', { commit: item.commit });
        source = { root: selected.root, commit };
      }
      if (item.path != null) {
        let input = item.path;
        if (req.source.kind === 'ref' && path.isAbsolute(input)) {
          const area = source.commit ? writtenAreaOf(path.resolve(input)) : areaOf(path.resolve(input));
          if (!area) fail('refused');
          const base = inside(area.lex, input) ? area.lex : area.real;
          input = path.join(selected.root, path.relative(base, input));
        }
        return [noteFile(source, input)];
      }
      if (!item.pattern) return [];
      const args = ['grep', '-l', '-z', '-I', '-E', '-e', item.pattern];
      if (source.commit) args.push(source.commit);
      const names = git(source.root, args, limit);
      if (names === null) return [];
      return names.toString('utf8').split('\0').filter(Boolean).map(name => protect(() => {
        const input = source.commit ? name.slice(source.commit.length + 1) : name;
        const reply = noteFile(source, input);
        return reply.ok ? { ...reply, path: path.relative(source.root, reply.path) } : reply;
      }));
    }
    function image(input) {
      const { root } = noteSource(req.imagesSource);
      if (input.startsWith('file:')) {
        try { input = decodeURIComponent(new URL(input).pathname); } catch { fail('refused'); }
      } else {
        if (/^[a-z][a-z0-9+.-]*:/i.test(input)) fail('refused');
        try { input = decodeURIComponent(input); } catch {}
      }
      if (!input || input.includes('\0') || input.startsWith('~')) fail('refused');
      const dirs = [root, ...req.temps].map(resolved);
      const candidate = resolved(path.resolve(root, input));
      const extensions = new Set(\#(String(decoding: try! JSONEncoder().encode(LocalImage.extensions.sorted()), as: UTF8.self)));
      if (!dirs.some(d => inside(d, candidate)) || !extensions.has(path.extname(candidate).slice(1).toLowerCase())) fail('refused');
      const reply = readFiles([{ path: candidate, roots: dirs, bytes: req.bytes, limit: Math.min(limit, remaining), metadataLimit: true }])[0];
      if (reply.ok) remaining -= reply.size;
      return { root, ...reply };
    }
    process.stdout.write(JSON.stringify({ fences: req.fences.map(item => {
      const result = protect(() => fence(item));
      return Array.isArray(result) ? result : [result];
    }), images: req.images.map(input => protect(() => image(input))) }));
    """#)
}
