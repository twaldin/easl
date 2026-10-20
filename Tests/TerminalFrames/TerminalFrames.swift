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

        var isRed: Bool { Int(red) - Int(max(green, blue)) > 80 }
        var isBlue: Bool { Int(blue) - Int(max(red, green)) > 80 }
    }

    var frames: [Frame] = []
    var invalidFrames = 0
    var consumeFrame: (@MainActor (FrameProbe, IOSurfaceRef, Frame) -> Void)?

    override func surfaceDidDraw() {
        guard let layer, let contents = layer.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
            invalidFrames += 1
            return
        }
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        guard let frame = Self.readFrame(surface, scale: layer.contentsScale) else {
            invalidFrames += 1
            return
        }
        frames.append(frame)
        consumeFrame?(self, surface, frame)
    }

    static func readFrame(_ surface: IOSurfaceRef, scale: CGFloat) -> Frame? {
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 40, height > 40, IOSurfaceGetBytesPerElement(surface) == 4 else { return nil }
        let base = IOSurfaceGetBaseAddress(surface)
        let pixel = base.advanced(by: 32 * IOSurfaceGetBytesPerRow(surface) + 32 * 4)
            .assumingMemoryBound(to: UInt8.self)
        return Frame(width: width, height: height, scale: scale,
                     red: pixel[2], green: pixel[1], blue: pixel[0])
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
        FileHandle.standardOutput.write(Data("window_backing_scale=\(window.backingScaleFactor)\n".utf8))
        defer {
            view.controller = nil
            window.close()
        }
        view.consumeFrame = { probe, surface, firstRed in
            guard firstRed.isRed else { return }
            probe.consumeFrame = nil
            let producer = DispatchGroup()
            DispatchQueue.global(qos: .userInitiated).async(group: producer) {
                for index in 0..<48 {
                    session.receive("\u{1b}[48;2;16;16;240m\u{1b}[2J\u{1b}[999;1HBLUE_LEASE_\(index)")
                    session.waitForPendingOutput()
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            producer.wait()
            precondition(session.readViewportText()?.contains("BLUE_LEASE_47") == true,
                         "background blue output was not parsed during the held-red callback")
            guard let heldRed = FrameProbe.readFrame(surface, scale: firstRed.scale) else {
                preconditionFailure("held red IOSurface became unreadable during surfaceDidDraw")
            }
            FileHandle.standardOutput.write(Data(
                "held_surface=\(IOSurfaceGetID(surface)) parsed_blue_updates=48 before_rgb=\(firstRed.red),\(firstRed.green),\(firstRed.blue) after_rgb=\(heldRed.red),\(heldRed.green),\(heldRed.blue)\n".utf8))
            precondition(heldRed.red == firstRed.red && heldRed.green == firstRed.green &&
                         heldRed.blue == firstRed.blue,
                         "completed red IOSurface pixels changed before surfaceDidDraw returned")
        }
        session.receive("\u{1b}[48;2;240;16;16m\u{1b}[2J\u{1b}[H")
        try await wait("first paint did not publish completed red pixels") {
            view.frames.contains { $0.isRed }
        }
        precondition(view.consumeFrame == nil, "the first red frame did not exercise its pixel consumer")
        try await wait("parsed blue output did not paint after the held-red callback returned") {
            guard let firstRed = view.frames.firstIndex(where: { $0.isRed }) else { return false }
            return view.frames.dropFirst(firstRed + 1).contains { $0.isBlue }
        }
        let beforeRedRestore = view.frames.count
        session.receive("\u{1b}[48;2;240;16;16m\u{1b}[2J\u{1b}[H")
        try await wait("red pixels did not return before the unchanged-cell draw cases") {
            view.frames.dropFirst(beforeRedRestore).contains { $0.isRed }
        }
        try await Task.sleep(for: .milliseconds(100))
        let beforeDraw = view.frames.count
        view.surface?.draw()
        try await wait("explicit draw did not publish a completed frame for unchanged red cells") {
            view.frames.dropFirst(beforeDraw).contains { $0.isRed }
        }
        try await Task.sleep(for: .milliseconds(100))
        let beforeDisplay = view.frames.count
        view.layer?.contents = nil
        view.layer?.setNeedsDisplay()
        try await wait("layer invalidation did not restore unchanged red pixels") {
            view.frames.dropFirst(beforeDisplay).contains { $0.isRed }
        }
        let beforeResize = view.frames.count
        window.setContentSize(NSSize(width: 640, height: 400))
        session.receive("\u{1b}[48;2;16;16;240m\u{1b}[2J\u{1b}[H")
        try await wait("resize did not publish completed blue pixels at the new scale and size") {
            view.frames.dropFirst(beforeResize).contains {
                $0.isBlue &&
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
        let callbackSession = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(callbackSession))
        view.consumeFrame = { probe, surface, firstBlue in
            guard firstBlue.isBlue else { return }
            probe.consumeFrame = nil
            precondition(callbackSession.readViewportText()?.contains("CALLBACK_FREE_BLUE") == true,
                         "callback teardown did not consume its completed blue output")
            callbackSession.receive("\u{1b}[48;2;240;16;16m\u{1b}[2J\u{1b}[999;1HCALLBACK_RETIRE_PENDING")
            callbackSession.waitForPendingOutput()
            precondition(callbackSession.readViewportText()?.contains("CALLBACK_RETIRE_PENDING") == true,
                         "callback teardown did not parse the output queued before free")
            Thread.sleep(forTimeInterval: 0.1)
            guard let beforeFree = FrameProbe.readFrame(surface, scale: firstBlue.scale) else {
                preconditionFailure("completed blue IOSurface became unreadable before callback teardown")
            }
            precondition(beforeFree.red == firstBlue.red && beforeFree.green == firstBlue.green &&
                         beforeFree.blue == firstBlue.blue,
                         "completed blue pixels changed before callback teardown")
            FileHandle.standardOutput.write(Data(
                "callback_free_surface=\(IOSurfaceGetID(surface)) pending_output_parsed=1 entering_free=1\n".utf8))
            probe.controller = nil
            precondition(probe.surface == nil && callbackSession.readViewportText() == nil,
                         "callback teardown did not detach and free its terminal surface")
            guard let afterFree = FrameProbe.readFrame(surface, scale: firstBlue.scale) else {
                preconditionFailure("completed IOSurface did not survive renderer teardown inside its callback")
            }
            precondition(afterFree.red == firstBlue.red && afterFree.green == firstBlue.green &&
                         afterFree.blue == firstBlue.blue,
                         "renderer teardown changed the callback's completed pixels")
            FileHandle.standardOutput.write(Data(
                "callback_free_surface=\(IOSurfaceGetID(surface)) free_returned=1 pixels_preserved=1\n".utf8))
        }
        let beforeCallbackFree = view.frames.count
        view.controller = controller
        callbackSession.receive("\u{1b}[48;2;16;16;240m\u{1b}[2J\u{1b}[999;1HCALLBACK_FREE_BLUE")
        try await wait("a completed blue callback did not finish freeing its surface") {
            view.controller == nil
        }
        precondition(view.consumeFrame == nil && view.frames.count > beforeCallbackFree,
                     "surface teardown did not run inside a completed-frame consumer")
        let afterCallbackFree = view.frames.count
        callbackSession.receive("\u{1b}[48;2;16;240;16m\u{1b}[2J")
        callbackSession.waitForPendingOutput()
        try await Task.sleep(for: .milliseconds(100))
        precondition(view.frames.count == afterCallbackFree,
                     "a surface freed inside its callback delivered a later completion")
        precondition(view.invalidFrames == 0, "a completion did not carry readable pixels")
        print("PASS completed first paint, held-callback red pixel ownership, parsed and painted blue output, explicit redraw, layer invalidation, resized pixels and scale, replacement, retired-surface completion isolation, and callback-triggered free with preserved pixels and no later completion")
        print("TERMINAL_FRAMES_COMPLETE")
    }
}
