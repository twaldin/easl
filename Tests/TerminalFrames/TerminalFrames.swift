import AppKit
@testable import GhosttyTerminal
import IOSurface

@MainActor
private final class FrameProbe: AppTerminalView {
    struct Frame {
        let width: Int
        let height: Int
        let scale: CGFloat
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    var frames: [Frame] = []
    var invalidFrames = 0

    override func surfaceDidDraw() {
        guard let layer, let contents = layer.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
            invalidFrames += 1
            return
        }
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else {
            invalidFrames += 1
            return
        }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 40, height > 40, IOSurfaceGetBytesPerElement(surface) == 4 else {
            invalidFrames += 1
            return
        }
        let base = IOSurfaceGetBaseAddress(surface)
        let pixel = base.advanced(by: 32 * IOSurfaceGetBytesPerRow(surface) + 32 * 4)
            .assumingMemoryBound(to: UInt8.self)
        frames.append(Frame(width: width, height: height, scale: layer.contentsScale,
                            red: pixel[2], green: pixel[1], blue: pixel[0]))
    }
}

@main
@MainActor
private enum TerminalFrames {
    static func wait(_ description: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            precondition(ContinuousClock.now < deadline, description)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func main() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let controller = TerminalController {
            $0.withCustom("cursor-style-blink", "false")
        }
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let view = FrameProbe(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.controller = controller
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            view.controller = nil
            window.close()
        }
        session.receive("\u{1b}[48;2;240;16;16m\u{1b}[2J\u{1b}[H")
        try await wait("first paint did not publish completed red pixels") {
            view.frames.contains { Int($0.red) - Int(max($0.green, $0.blue)) > 80 }
        }
        try await Task.sleep(for: .milliseconds(100))
        let beforeDraw = view.frames.count
        view.surface?.draw()
        try await wait("explicit draw did not publish a completed frame for unchanged red cells") {
            view.frames.dropFirst(beforeDraw).contains { Int($0.red) - Int(max($0.green, $0.blue)) > 80 }
        }
        try await Task.sleep(for: .milliseconds(100))
        let beforeDisplay = view.frames.count
        view.layer?.contents = nil
        view.layer?.setNeedsDisplay()
        try await wait("layer invalidation did not restore unchanged red pixels") {
            view.frames.dropFirst(beforeDisplay).contains { Int($0.red) - Int(max($0.green, $0.blue)) > 80 }
        }
        let beforeResize = view.frames.count
        window.setContentSize(NSSize(width: 640, height: 400))
        session.receive("\u{1b}[48;2;16;16;240m\u{1b}[2J\u{1b}[H")
        try await wait("resize did not publish completed blue pixels at the new scale and size") {
            view.frames.dropFirst(beforeResize).contains {
                Int($0.blue) - Int(max($0.red, $0.green)) > 80 &&
                $0.scale == window.backingScaleFactor &&
                $0.width == Int(view.bounds.width * $0.scale) &&
                $0.height == Int(view.bounds.height * $0.scale)
            }
        }
        precondition(view.invalidFrames == 0, "surfaceDidDraw ran without readable completed pixels")
        let replacement = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(replacement))
        let afterReplacement = view.frames.count
        replacement.receive("\u{1b}[48;2;16;240;16m\u{1b}[2J\u{1b}[H")
        try await wait("replacement surface did not publish its own completed green frame") {
            view.frames.dropFirst(afterReplacement).contains { Int($0.green) - Int(max($0.red, $0.blue)) > 80 }
        }
        replacement.receive("\u{1b}[48;2;16;16;240m\u{1b}[2J")
        replacement.waitForPendingOutput()
        view.controller = nil
        let afterFree = view.frames.count
        session.receive("\u{1b}[48;2;240;16;16m\u{1b}[2J")
        replacement.receive("\u{1b}[48;2;16;16;240m\u{1b}[2J")
        try await Task.sleep(for: .milliseconds(100))
        precondition(view.frames.count == afterFree, "a retired surface delivered a completion")
        precondition(view.invalidFrames == 0, "a completion did not carry readable pixels")
        print("PASS completed first paint, explicit redraw, layer invalidation, resized pixels and scale, replacement, and retired-surface completion isolation")
        print("TERMINAL_FRAMES_COMPLETE")
    }
}
