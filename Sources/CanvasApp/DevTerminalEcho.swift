import AppKit
import CanvasCore
import GhosttyKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Darwin

@MainActor
enum DevTerminalEcho {
    private static var capture: EchoCapture?
    private static weak var terminal: CanvasTerminalView?
    private static var keys = 0
    private static var updated = 0
    private static var expected = 100
    private static var sampler: DispatchSourceTimer?

    static func control(_ fields: [String: String]) {
        guard DevInput.enabled, #available(macOS 14.4, *) else { return }
        if fields["action"] == "stop" {
            let old = capture
            capture = nil
            terminal = nil
            sampler?.cancel()
            sampler = nil
            Task { try? await old?.stop() }
            return
        }
        guard capture == nil, fields["action"] == "start",
              let number = Int(fields["window"] ?? ""), let window = NSApp.window(withWindowNumber: number),
              let view = window.firstResponder as? CanvasTerminalView,
              let surface = (view.superview as? TerminalTile)?.surface?.handle, let content = window.contentView,
              let path = fields["directory"], path.hasPrefix("/") else { return }
        let count = Int(fields["count"] ?? "100") ?? 0
        guard count == 1 || count == 100 else { return }
        let size = ghostty_surface_size(surface)
        guard size.columns >= 22, size.rows >= 13 else { return }
        let scale = window.backingScaleFactor
        let style = TerminalConfig.shared.style(for: view.effectiveAppearance)
        let cell = CGSize(width: CGFloat(size.cell_width_px) / scale, height: CGFloat(size.cell_height_px) / scale)
        let origin = view.convert(NSPoint(x: style.padding.width, y: view.bounds.maxY - style.padding.height), to: nil)
        let screen = window.convertPoint(toScreen: origin)
        let rect = CGRect(x: screen.x - window.frame.minX, y: window.frame.maxY - screen.y,
                          width: cell.width, height: cell.height)
        do {
            let output = try EchoCapture(directory: URL(fileURLWithPath: path), cell: rect, window: window.windowNumber,
                                         width: Int(window.frame.width * scale), height: Int(window.frame.height * scale), scale: scale, count: count)
            capture = output
            terminal = view
            keys = 0
            expected = count
            updated = 0
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .nanoseconds(0))
            timer.setEventHandler { MainActor.assumeIsolated { sample() } }
            sampler = timer
            timer.resume()
            output.record("probe.start", fields: ["window": number, "contentHeight": content.bounds.height,
                          "cell": [rect.minX, rect.minY, rect.width, rect.height], "columns": size.columns, "rows": size.rows, "surface_sample_ms": 2])
            Task {
                do {
                    let own = try await SCShareableContent.currentProcess
                    guard let selected = own.windows.first(where: { $0.windowID == CGWindowID(number) && $0.owningApplication?.processID == getpid() }) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try await output.start(selected)
                } catch { output.record("probe.error", fields: ["error": String(describing: error)]) }
            }
        } catch { NSLog("easl: terminal echo probe: %@", String(describing: error)) }
    }

    static func key(_ view: CanvasTerminalView, event: NSEvent) {
        guard terminal === view, let capture else { return }
        keys += 1
        capture.record("viewer.key", fields: ["seq": keys, "keyCode": event.keyCode,
                       "ascii": Array((event.characters ?? "").utf8), "eventUptime": event.timestamp])
    }

    private static func sample() {
        guard let view = terminal, let capture, updated < min(keys, expected) else { return }
        while updated < min(keys, expected) {
            let row = updated / 10
            guard let text = (view.superview as? TerminalTile)?.surface?.viewportRow(row + 2, columns: 22) else { return }
            let ticks = mach_absolute_time()
            let cells = Array(text.utf8)
            repeat {
                let offset = updated % 10 * 2 + 2
                guard offset < cells.count, cells[offset] == 97 else { return }
                updated += 1
                capture.record("surface.updated", ticks: ticks, fields: ["seq": updated])
            } while updated < min(keys, expected) && updated / 10 == row
        }
        if updated == expected {
            sampler?.cancel()
            sampler = nil
        }
    }
}

private final class EchoCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "canvas.dev.terminal-echo")
    private let directory: URL
    private let log: FileHandle
    private let cell: CGRect
    private let window: Int
    private let width: Int
    private let height: Int
    private let scale: CGFloat
    private let count: Int
    private var stream: SCStream?
    private var ready = false
    private var seen: Set<Int> = []
    private var lastDisplay: UInt64 = 0
    private var frame = 0
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    init(directory: URL, cell: CGRect, window: Int, width: Int, height: Int, scale: CGFloat, count: Int) throws {
        self.directory = directory
        self.cell = cell
        self.window = window
        self.width = width
        self.height = height
        self.scale = scale
        self.count = count
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("viewer.jsonl")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func ms(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    func record(_ stage: String, ticks: UInt64 = mach_absolute_time(), fields: [String: Any] = [:]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields.merging([
            "stage": stage, "ts_ms": Self.ms(ticks), "ticks": String(ticks), "pid": getpid(),
            "clock_domain": "mach_absolute_time", "timebase_numer": Self.timebase.numer, "timebase_denom": Self.timebase.denom
        ]) { _, new in new }) + Data([10]) else { return }
        queue.async { [self] in try? log.write(contentsOf: data) }
    }

    @MainActor func start(_ selected: SCWindow) async throws {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.queueDepth = 3
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: selected), configuration: config, delegate: self)
        queue.sync { self.stream = stream }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    @MainActor func stop() async throws {
        let current = queue.sync { stream }
        try await current?.stopCapture()
        try current?.removeStreamOutput(self, type: .screen)
        record("probe.stopped", fields: ["observed": queue.sync { seen.count }])
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        record("probe.error", fields: ["error": String(describing: error)])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        let receipt = mach_absolute_time()
        guard type == .screen, CMSampleBufferIsValid(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = info[.status] as? NSNumber,
              status.intValue == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sample), let stamp = info[.displayTime] as? NSNumber else { return }
        let display = stamp.uint64Value
        guard display > 0, display <= receipt, display >= lastDisplay,
              CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height,
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else {
            record("probe.error", fields: ["error": "invalid native frame timing or geometry"])
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return }
        lastDisplay = display
        frame += 1
        let stride = CVPixelBufferGetBytesPerRow(image)
        var newlySeen: [Int] = []
        for seq in 1...count where !seen.contains(seq) {
            let row = (seq - 1) / 10 + 2, column = (seq - 1) % 10 * 2 + 2
            let left = Int((cell.minX + CGFloat(column) * cell.width) * scale)
            let top = Int((cell.minY + CGFloat(row) * cell.height) * scale)
            let right = Int((cell.minX + CGFloat(column + 1) * cell.width) * scale)
            let bottom = Int((cell.minY + CGFloat(row + 1) * cell.height) * scale)
            guard left >= 0, top >= 0, right <= width, bottom <= height else {
                record("probe.error", fields: ["error": "cell outside native frame", "seq": seq])
                return
            }
            var white = 0, blue = 0
            for y in top..<bottom {
                for x in left..<right {
                    let p = base.assumingMemoryBound(to: UInt8.self) + y * stride + x * 4
                    if p[0] > 200 && p[1] > 200 && p[2] > 200 { white += 1 }
                    if p[0] > 100 && p[1] < 100 && p[2] < 100 { blue += 1 }
                }
            }
            if white >= 3 && blue >= 3 {
                seen.insert(seq)
                newlySeen.append(seq)
                record("screen.glyph", ticks: display, fields: ["seq": seq, "receipt_ms": Self.ms(receipt),
                       "observer_ms": Self.ms(receipt - display), "frame": frame, "white_pixels": white, "blue_pixels": blue])
            }
        }
        if !ready || seen.count == count && !newlySeen.isEmpty {
            let name = ready ? "complete.png" : "ready.png"
            do {
                try save(base, stride: stride, name: name)
                let fields: [String: Any] = ["stage": ready ? "screen.complete" : "screen.ready", "ts_ms": Self.ms(display),
                                             "receipt_ms": Self.ms(receipt), "seen": seen.count, "window": window, "png": name]
                try writeProbeArtifact(JSONSerialization.data(withJSONObject: fields), to: directory.appendingPathComponent(ready ? "complete.json" : "ready.json"))
                ready = true
            } catch { record("probe.error", fields: ["error": String(describing: error)]) }
        }
    }

    private func save(_ base: UnsafeRawPointer, stride: Int, name: String) throws {
        let bytes = Data(bytes: base, count: stride * height)
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try writeProbeArtifact(data as Data, to: directory.appendingPathComponent(name))
    }
}
