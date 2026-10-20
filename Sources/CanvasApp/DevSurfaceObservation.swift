import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Darwin

@MainActor
enum DevSurfaceObservation {
    private static var generation = UUID()
    private static var capture: OwnWindowCapture?
    private static var closing: NSObjectProtocol?
    private static var busy = false

    static func control(_ fields: [String: String]) {
        guard DevInput.enabled else { return }
        guard #available(macOS 14.4, *) else {
            report(fields, "own-window observation requires macOS 14.4 or later")
            return
        }
        let action = fields["action"] ?? ""
        if action == "arm" {
            guard let capture, fields["session"] == capture.session else {
                report(fields, "no matching own-window session")
                return
            }
            guard let number = Int(fields["window"] ?? ""), let window = NSApp.window(withWindowNumber: number),
                  capture.matchesGeometry(window) else {
                report(fields, "own NSWindow geometry changed during recording")
                return
            }
            capture.arm(fields)
            return
        }
        guard action == "start" || action == "stop", !busy else {
            report(fields, "invalid action or capture lifecycle busy")
            return
        }
        if action == "stop", fields["session"] != capture?.session {
            report(fields, "no matching own-window session")
            return
        }
        busy = true
        generation = UUID()
        let token = generation
        Task { @MainActor in
            defer { busy = false }
            do {
                if let old = capture {
                    capture = nil
                    if let closing { NotificationCenter.default.removeObserver(closing) }
                    closing = nil
                    try await old.stop()
                }
                guard action == "start", generation == token else { return }
                guard let number = Int(fields["window"] ?? ""),
                      let window = NSApp.window(withWindowNumber: number), let content = window.contentView,
                      let x = Double(fields["x"] ?? ""), let y = Double(fields["y"] ?? ""),
                      x.isFinite, y.isFinite, x >= 0, y >= 0,
                      x < content.bounds.width, y < content.bounds.height,
                      let directory = fields["directory"], directory.hasPrefix("/"),
                      let session = fields["session"], !session.isEmpty else {
                    throw ProbeError("start requires exact own window, content point, absolute directory and session")
                }
                let own = try await SCShareableContent.currentProcess
                guard generation == token else { return }
                guard let selected = own.windows.first(where: {
                    $0.windowID == CGWindowID(number) && $0.owningApplication?.processID == getpid()
                }) else { throw ProbeError("exact own NSWindow absent from currentProcess") }
                let point = content.convert(NSPoint(x: content.bounds.minX + x, y: content.bounds.maxY - y), to: nil)
                let screen = window.convertPoint(toScreen: point)
                let fraction = CGPoint(x: (screen.x - window.frame.minX) / window.frame.width,
                                       y: (window.frame.maxY - screen.y) / window.frame.height)
                let output = try OwnWindowCapture(session: session, directory: URL(fileURLWithPath: directory),
                                                 window: number, fraction: fraction, size: window.frame.size,
                                                 contentPoint: CGPoint(x: x, y: y), backingScale: window.backingScaleFactor,
                                                 captureReady: fields["captureReady"] == "1")
                capture = output
                closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    Task { @MainActor in
                        guard capture === output else { return }
                        control(["action": "stop", "session": output.session])
                    }
                }
                try await output.start(selected)
                guard generation == token, capture === output else {
                    try await output.stop()
                    return
                }
            } catch {
                capture = nil
                if let closing { NotificationCenter.default.removeObserver(closing) }
                closing = nil
                report(fields, String(describing: error))
            }
        }
    }

    private static func report(_ fields: [String: String], _ message: String) {
        let value = ProbeClock().timestampFields.merging([
            "stage": "screen.error", "session": fields["session"] ?? "",
            "pid": getpid(), "window": Int(fields["window"] ?? "") ?? -1,
            "error": message
        ]) { _, new in new }
        if let directory = fields["directory"], directory.hasPrefix("/"),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? writeProbeArtifact(data, to: URL(fileURLWithPath: directory).appendingPathComponent("error.json"))
        }
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            print("DevInput.surface \(String(decoding: data, as: UTF8.self))")
            fflush(stdout)
        }
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func writeProbeArtifact(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.linkItem(at: temporary, to: url)
}

private struct ProbeClock {
    private static let timebase: (UInt32, UInt32) = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return (value.numer, value.denom)
    }()
    let a: UInt64
    let b: UInt64
    let numer: UInt32
    let denom: UInt32

    init() {
        numer = Self.timebase.0
        denom = Self.timebase.1
        a = mach_absolute_time()
        b = mach_absolute_time()
    }

    var factor: Double { Double(numer) / Double(denom) / 1_000_000 }
    func delta(_ lhs: UInt64, _ rhs: UInt64) -> Double {
        lhs >= rhs ? Double(lhs - rhs) * factor : -Double(rhs - lhs) * factor
    }
    func milliseconds(_ ticks: UInt64) -> Double { Double(ticks) * factor }
    var timestampFields: [String: Any] {
        ["clock_domain": "mach_absolute_time", "ts_ticks": String(b), "ts_ms": milliseconds(b),
         "timebase_numer": numer, "timebase_denom": denom]
    }
    var fields: [String: Any] {
        ["clock_domain": "mach_absolute_time", "a_ticks": String(a), "b_ticks": String(b),
         "timebase_numer": numer, "timebase_denom": denom]
    }
}

private final class OwnWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let session: String
    private let directory: URL
    private let window: Int
    private let fraction: CGPoint
    private let size: CGSize
    private let contentPoint: CGPoint
    private let backingScale: CGFloat
    private let captureReady: Bool
    private let queue = DispatchQueue(label: "canvas.dev.own-window-observation")
    private let origin: ProbeClock
    private var previous: ProbeClock?
    private var stream: SCStream?
    private var active = true
    private var ready = false
    private var lastPixel: [Int]?
    private var lastDisplay: UInt64 = 0
    private struct Arm {
        let label: String
        let target: [Int]
        let ticks: UInt64
    }
    private var armed: Arm?
    private var usedLabels: Set<String> = []

    init(session: String, directory: URL, window: Int, fraction: CGPoint, size: CGSize, contentPoint: CGPoint, backingScale: CGFloat, captureReady: Bool) throws {
        self.session = session
        self.directory = directory
        self.window = window
        self.fraction = fraction
        self.size = size
        self.contentPoint = contentPoint
        self.backingScale = backingScale
        self.captureReady = captureReady
        let clock = ProbeClock()
        origin = clock
        super.init()
        guard fraction.x >= 0, fraction.x < 1, fraction.y >= 0, fraction.y < 1 else {
            throw ProbeError("content point outside full NSWindow")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProbeError("artifact directory must already exist")
        }
        try check(clock)
        try emit("screen.starting", file: "starting.json", fields: ["origin_clock": origin.fields])
    }

    @MainActor func matchesGeometry(_ current: NSWindow) -> Bool {
        guard current.windowNumber == window, current.frame.size == size,
              current.backingScaleFactor == backingScale, let content = current.contentView else { return false }
        let point = content.convert(NSPoint(x: content.bounds.minX + contentPoint.x, y: content.bounds.maxY - contentPoint.y), to: nil)
        let screen = current.convertPoint(toScreen: point)
        return abs((screen.x - current.frame.minX) / size.width - fraction.x) < 0.0001
            && abs((current.frame.maxY - screen.y) / size.height - fraction.y) < 0.0001
    }

    @MainActor func start(_ window: SCWindow) async throws {
        let config = SCStreamConfiguration()
        config.width = Int((size.width * backingScale).rounded())
        config.height = Int((size.height * backingScale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = false
        config.queueDepth = 3
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        queue.sync { self.stream = stream }
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            queue.sync { active = false; self.stream = nil; fail(error) }
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            throw error
        }
    }

    func arm(_ fields: [String: String]) {
        queue.async { [self] in
            do {
                guard active, ready, let pixel = lastPixel,
                      let label = fields["sample"], !label.isEmpty,
                      label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                      !usedLabels.contains(label),
                      let r = Int(fields["r"] ?? ""), let g = Int(fields["g"] ?? ""), let b = Int(fields["b"] ?? ""),
                      [r, g, b].allSatisfy({ (0...255).contains($0) }),
                      zip(pixel, [r, g, b]).contains(where: { abs($0 - $1) > 32 }) else {
                    throw ProbeError("arm requires ready stream, unused sample and a new RGB target more than 32 from current pixel")
                }
                let clock = ProbeClock()
                try check(clock)
                if let pending = armed {
                    try emit("screen.missing", file: "\(pending.label)-missing.json", fields: ["sample": pending.label])
                }
                usedLabels.insert(label)
                armed = Arm(label: label, target: [r, g, b], ticks: clock.b)
                try emit("screen.armed", file: "\(label)-armed.json", fields: ["sample": label, "target": [r, g, b],
                    "before_pixel": pixel, "before_display_ticks": String(lastDisplay), "arm_ticks": String(clock.b), "clock": clock.fields])
            } catch { fail(error) }
        }
    }

    @MainActor func stop() async throws {
        let current = queue.sync { () -> SCStream? in
            active = false
            let current = stream
            stream = nil
            return current
        }
        do {
            if let current {
                try await current.stopCapture()
                try current.removeStreamOutput(self, type: .screen)
            }
            try queue.sync {
                if let pending = armed {
                    try emit("screen.missing", file: "\(pending.label)-missing.json", fields: ["sample": pending.label])
                    armed = nil
                }
                let clock = ProbeClock()
                try check(clock)
                try emit("screen.stopped", file: "stopped.json", fields: ["clock": clock.fields])
            }
        } catch {
            if let current { try? current.removeStreamOutput(self, type: .screen) }
            queue.sync { fail(error) }
            throw error
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard active, self.stream === stream else { return }
            fail(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        let receipt = mach_absolute_time()
        guard active, self.stream === stream, type == .screen else { return }
        do {
            let clock = ProbeClock()
            try check(clock)
            guard CMSampleBufferIsValid(sample),
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let info = attachments.first,
                  let status = info[.status] as? NSNumber else { throw ProbeError("missing native frame metadata") }
            guard status.intValue == SCFrameStatus.complete.rawValue else { return }
            guard let image = CMSampleBufferGetImageBuffer(sample),
                  let display = (info[.displayTime] as? NSNumber)?.uint64Value,
                  display > 0, display <= receipt, display >= lastDisplay,
                  let rectValue = info[.contentRect] as? [String: Any],
                  let rawRect = CGRect(dictionaryRepresentation: rectValue as CFDictionary),
                  let contentScale = info[.contentScale] as? NSNumber,
                  let scaleFactor = info[.scaleFactor] as? NSNumber,
                  CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else {
                throw ProbeError("invalid complete frame timing, geometry or BGRA format")
            }
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            let scale = CGFloat(scaleFactor.doubleValue)
            let rect = CGRect(x: rawRect.minX * scale, y: rawRect.minY * scale,
                              width: rawRect.width * scale, height: rawRect.height * scale)
            guard scale.isFinite, scale > 0,
                  rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
                  rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0,
                  rect.maxX <= CGFloat(width) + 1, rect.maxY <= CGFloat(height) + 1,
                  abs(rect.width / rect.height - size.width / size.height) < 0.01,
                  abs(contentScale.doubleValue - 1) < 0.001 else { throw ProbeError("unexpected scaled or cropped window capture") }
            let x = Int((rect.minX + fraction.x * rect.width).rounded(.down))
            let y = Int((rect.minY + fraction.y * rect.height).rounded(.down))
            guard x >= 0, x < width, y >= 0, y < height,
                  CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { throw ProbeError("unreadable marker pixel") }
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(image) else { throw ProbeError("missing BGRA base address") }
            let stride = CVPixelBufferGetBytesPerRow(image)
            let p = base.assumingMemoryBound(to: UInt8.self) + y * stride + x * 4
            let pixel = [Int(p[2]), Int(p[1]), Int(p[0])]
            lastPixel = pixel
            lastDisplay = display
            let matches = armed.map { arm in display > arm.ticks && zip(pixel, arm.target).allSatisfy { abs($0 - $1) <= 16 } } ?? false
            guard !ready || matches else { return }
            var fields: [String: Any] = ["pixel": pixel, "width": width, "height": height, "bytes_per_row": stride,
                "marker_pixel": [x, y], "content_point": [contentPoint.x, contentPoint.y],
                "window_fraction": [fraction.x, fraction.y], "window_size": [size.width, size.height],
                "content_rect": [rawRect.minX, rawRect.minY, rawRect.width, rawRect.height],
                "content_rect_pixels": [rect.minX, rect.minY, rect.width, rect.height],
                "content_scale": contentScale, "scale_factor": scaleFactor, "backing_scale": backingScale,
                "color_space": "sRGB",
                "frame_status": status.intValue, "display_ticks": String(display), "receipt_ticks": String(receipt),
                "clock": clock.fields, "origin_clock": origin.fields, "clock_valid": true,
                "display_ms": clock.milliseconds(display)]
            fields["frame_metadata"] = Dictionary(uniqueKeysWithValues: info.map {
                (String(describing: $0.key), ["value": String(describing: $0.value), "type": String(describing: Swift.type(of: $0.value))])
            })
            if !ready {
                if captureReady {
                    fields["png"] = try saveFrame(base, width: width, height: height, stride: stride, file: "ready-frame.png").path
                }
                ready = true
                try emit("screen.ready", file: "ready.json", fields: fields)
            }
            if matches, let arm = armed {
                let png = try saveFrame(base, width: width, height: height, stride: stride, file: "\(arm.label)-native.png")
                fields["sample"] = arm.label
                fields["target"] = arm.target
                fields["arm_ticks"] = String(arm.ticks)
                fields["png"] = png.path
                try emit("screen.observed", file: "\(arm.label)-observed.json", fields: fields)
                armed = nil
            }
        } catch { fail(error) }
    }

    private func saveFrame(_ base: UnsafeRawPointer, width: Int, height: Int, stride: Int, file: String) throws -> URL {
        let png = directory.appendingPathComponent(file)
        let bytes = Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ProbeError("cannot retain native evidence") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ProbeError("cannot create native PNG") }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw ProbeError("cannot encode native PNG") }
        try writeProbeArtifact(data as Data, to: png)
        return png
    }

    private func check(_ clock: ProbeClock) throws {
        guard clock.numer > 0, clock.denom > 0, clock.a <= clock.b, clock.a >= (previous?.b ?? 0),
              clock.numer == origin.numer, clock.denom == origin.denom,
              clock.delta(clock.b, clock.a) <= 2 else {
            let error = ProbeError("invalid mach timebase, tick order or excessive sampling interval")
            try? emit("screen.error", file: "error.json", fields: ["error": error.description,
                "clock": clock.fields, "previous_clock": previous?.fields ?? [:], "origin_clock": origin.fields])
            throw error
        }
        previous = clock
    }

    private func fail(_ error: Error) {
        active = false
        try? emit("screen.error", file: "error.json", fields: ["error": String(describing: error)])
    }

    private func emit(_ stage: String, file: String, fields: [String: Any]) throws {
        let value = fields.merging(ProbeClock().timestampFields) { _, new in new }
            .merging(["stage": stage, "session": session, "pid": getpid(), "window": window]) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try writeProbeArtifact(data, to: directory.appendingPathComponent(file))
        print("DevInput.surface \(String(decoding: data, as: UTF8.self))")
        fflush(stdout)
    }
}
