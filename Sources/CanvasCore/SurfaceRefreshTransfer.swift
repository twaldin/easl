import Foundation

public enum SurfaceRefreshTransferError: Error, Equatable {
    case invalidFrame
    case invalidOffset
    case inconsistentFrame
}

public struct SurfaceRefreshTransmission: Sendable {
    public static let chunkBytes = 16 * 1024
    public static let maximumBytes = 576 * 1024

    private let windowBytes: Int
    private let frame: SurfaceEvent.Frame
    private var sentBytes = 0
    private var acknowledgedBytes = 0

    public init(frame: SurfaceEvent.Frame, refinement: SurfaceRefinement = .retained) throws {
        try validateRefresh(frame)
        guard frame.offset == nil, frame.total == nil,
              (1...Self.maximumBytes).contains(frame.data.count) else {
            throw SurfaceRefreshTransferError.invalidFrame
        }
        self.frame = frame
        windowBytes = (refinement == .independent ? 1 : 8) * Self.chunkBytes
    }

    public mutating func start() -> [SurfaceEvent.Frame] {
        guard sentBytes == 0 else { return [] }
        return fillWindow()
    }

    public mutating func progress(offset: Int) throws -> [SurfaceEvent.Frame] {
        guard offset >= 0, offset.isMultiple(of: Self.chunkBytes), offset < sentBytes else {
            throw SurfaceRefreshTransferError.invalidOffset
        }
        let boundary = min(offset + Self.chunkBytes, frame.data.count)
        guard boundary > acknowledgedBytes else { return [] }
        acknowledgedBytes = boundary
        return fillWindow()
    }

    private mutating func fillWindow() -> [SurfaceEvent.Frame] {
        let limit = min(acknowledgedBytes + windowBytes, frame.data.count)
        guard sentBytes < limit else { return [] }
        var parts: [SurfaceEvent.Frame] = []
        parts.reserveCapacity((limit - sentBytes + Self.chunkBytes - 1) / Self.chunkBytes)
        while sentBytes < limit {
            let end = min(sentBytes + Self.chunkBytes, limit)
            var part = frame
            part.offset = sentBytes
            part.total = frame.data.count
            part.data = frame.data.subdata(in: (frame.data.startIndex + sentBytes)..<(frame.data.startIndex + end))
            sentBytes = end
            parts.append(part)
        }
        return parts
    }
}

public struct SurfaceRefreshAssembly: Sendable {
    private var metadata: SurfaceEvent.Frame?
    private var total = 0
    private var data = Data()

    public init() {}

    public mutating func reset() {
        metadata = nil
        total = 0
        data = Data()
    }

    public mutating func append(frame: SurfaceEvent.Frame) throws -> SurfaceEvent.Frame? {
        try validateRefresh(frame)
        guard let offset = frame.offset, let total = frame.total,
              (1...SurfaceRefreshTransmission.maximumBytes).contains(total),
              offset >= 0, offset < total,
              offset.isMultiple(of: SurfaceRefreshTransmission.chunkBytes),
              frame.data.count == min(SurfaceRefreshTransmission.chunkBytes, total - offset) else {
            throw SurfaceRefreshTransferError.invalidFrame
        }
        var incoming = frame
        incoming.data = Data()
        incoming.offset = nil
        incoming.total = nil
        let replaces = metadata.map { frame.stream == $0.stream && frame.seq > $0.seq } ?? true
        if replaces {
            guard offset == 0 else { throw SurfaceRefreshTransferError.invalidOffset }
            reset()
            metadata = incoming
            self.total = total
            data.reserveCapacity(total)
        }
        guard metadata == incoming, self.total == total else {
            throw SurfaceRefreshTransferError.inconsistentFrame
        }
        guard offset == data.count else { throw SurfaceRefreshTransferError.invalidOffset }
        data.append(frame.data)
        guard data.count == total else { return nil }
        var completed = incoming
        completed.data = data
        reset()
        return completed
    }
}

private func validateRefresh(_ frame: SurfaceEvent.Frame) throws {
    guard frame.refresh, frame.format == .h264,
          !frame.stream.isEmpty, (1...SurfaceRequest.maxInteger).contains(frame.seq),
          (0...SurfaceRequest.maxInteger).contains(frame.input),
          frame.width > 0, frame.height > 0,
          frame.width <= SurfaceEvent.Frame.maxPixels / frame.height,
          frame.scale.isFinite, frame.scale > 0,
          frame.size.width.isFinite, frame.size.height.isFinite,
          frame.size.width > 0, frame.size.height > 0 else {
        throw SurfaceRefreshTransferError.invalidFrame
    }
    if let canvas = frame.canvas {
        guard canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0,
              canvas.width.rounded(.down) == canvas.width, canvas.height.rounded(.down) == canvas.height,
              canvas.width <= CGFloat(SurfaceEvent.Frame.maxPixels) / canvas.height else {
            throw SurfaceRefreshTransferError.invalidFrame
        }
    }
    if let supersedes = frame.supersedes, !(1..<frame.seq).contains(supersedes) {
        throw SurfaceRefreshTransferError.invalidFrame
    }
}
