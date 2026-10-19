import Darwin
import Foundation

public enum LocalVideo {
    public static func problem(_ props: JSONValue) -> String? {
        guard let path = props["path"]?.string, !path.isEmpty else { return "a video needs props.path" }
        for key in ["poster", "title"] where props[key] != nil {
            if props[key]?.string == nil { return "video props.\(key) must be a string" }
        }
        for key in ["loop", "muted", "autoplay"] where props[key] != nil {
            if case .bool = props[key]! {} else { return "video props.\(key) must be a boolean" }
        }
        if let value = props["startTime"], value.number == nil || !value.number!.isFinite || value.number! < 0 {
            return "video props.startTime must be a nonnegative number"
        }
        return nil
    }

    public static func naturalSize(path: String, root: URL) async throws -> CGSize {
        try await offPool {
            Result {
                let file: HostLocalFile
                do {
                    file = try HostLocalFile(HostFileRequest(source: .directory(root.path), policy: .boardAsset(path), bytes: false))
                } catch {
                    throw ObjectMeasure.Failure.invalidParams("video path refused")
                }
                let descriptor: Int32
                do {
                    descriptor = try BoardAreas.openNoFollow(file.path)
                } catch {
                    throw ObjectMeasure.Failure.notFound("no readable video at \(path)")
                }
                defer { close(descriptor) }
                var before = stat()
                guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else {
                    throw ObjectMeasure.Failure.unavailable("video is not a regular file")
                }
                let size = try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 96) { buffer in
                    var reader = HeaderWalk(descriptor: descriptor, buffer: buffer)
                    guard let size = try reader.boxes(start: 0, end: Int64(before.st_size), depth: 0, context: .file).size else {
                        throw HeaderWalk.failure
                    }
                    return size
                }
                var after = stat()
                guard fstat(descriptor, &after) == 0,
                      before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                      before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                    throw ObjectMeasure.Failure.unavailable("video changed while measuring")
                }
                return size
            }
        }.get()
    }

    private struct HeaderWalk {
        enum Context { case file, movie, track, media }
        enum Kind: UInt32 {
            case unknown = 0
            case moov = 0x6d6f6f76
            case trak = 0x7472616b
            case mdia = 0x6d646961
            case hdlr = 0x68646c72
            case tkhd = 0x746b6864
        }
        struct Track {
            var dimensions: CGSize?
            var video = false
            var size: CGSize? { video ? dimensions : nil }
        }

        static var failure: ObjectMeasure.Failure {
            .unavailable("video dimensions unavailable: a readable MP4 or MOV video track is required")
        }

        let descriptor: Int32
        let buffer: UnsafeMutableBufferPointer<UInt8>
        var budget = 8192

        func read(_ count: Int, at offset: Int64) throws {
            var used = 0
            while used < count {
                let n = pread(descriptor, buffer.baseAddress!.advanced(by: used), count - used, off_t(offset + Int64(used)))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw Self.failure }
                used += n
            }
        }

        func word(_ offset: Int) -> UInt32 {
            UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 |
                UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
        }

        mutating func boxes(start: Int64, end: Int64, depth: Int, context: Context) throws -> Track {
            guard depth <= 4 else { throw Self.failure }
            var track = Track()
            var offset = start
            while offset < end {
                guard end - offset >= 8, budget > 0 else { throw Self.failure }
                budget -= 1
                try read(8, at: offset)
                var length = UInt64(word(0))
                let kind = Kind(rawValue: word(4)) ?? .unknown
                var header: Int64 = 8
                if length == 1 {
                    guard end - offset >= 16 else { throw Self.failure }
                    try read(8, at: offset + 8)
                    length = UInt64(word(0)) << 32 | UInt64(word(4))
                    header = 16
                } else if length == 0 {
                    length = UInt64(end - offset)
                }
                guard length >= UInt64(header), length <= UInt64(end - offset) else { throw Self.failure }
                let body = offset + header
                let next = offset + Int64(length)
                switch (context, kind) {
                case (.file, .moov), (.movie, .trak):
                    let childContext: Context = context == .file ? .movie : .track
                    let child = try boxes(start: body, end: next, depth: depth + 1, context: childContext)
                    if child.size != nil { return child }
                case (.track, .mdia):
                    track.video = try boxes(start: body, end: next, depth: depth + 1, context: .media).video
                case (.media, .hdlr):
                    guard next - body >= 12 else { throw Self.failure }
                    try read(12, at: body)
                    track.video = word(8) == 0x76696465
                    if track.video { return track }
                case (.track, .tkhd):
                    guard next - body >= 84 else { throw Self.failure }
                    try read(84, at: body)
                    let matrix: Int
                    let dimensions: Int
                    switch buffer[0] {
                    case 0: (matrix, dimensions) = (40, 76)
                    case 1:
                        guard next - body >= 96 else { throw Self.failure }
                        try read(96, at: body)
                        (matrix, dimensions) = (52, 88)
                    default: throw Self.failure
                    }
                    let width = Double(word(dimensions)) / 65536
                    let height = Double(word(dimensions + 4)) / 65536
                    func fixed(_ at: Int) -> Double { Double(Int32(bitPattern: word(at))) / 65536 }
                    let w = abs(fixed(matrix)) * width + abs(fixed(matrix + 12)) * height
                    let h = abs(fixed(matrix + 4)) * width + abs(fixed(matrix + 16)) * height
                    if width > 0, height > 0, w.isFinite, h.isFinite, w > 0, h > 0 {
                        track.dimensions = CGSize(width: w, height: h)
                    }
                default: break
                }
                if track.size != nil { return track }
                offset = next
            }
            return track
        }
    }
}
