//
//  AppTerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit

    @MainActor
    open class AppTerminalView: NSView {
        let core = TerminalSurfaceCoordinator()
        var metalLayer: CAMetalLayer?
        var inputHandler: TerminalKeyEventHandler?
        private var nativeFrameObservation: NSKeyValueObservation?

        override open var layer: CALayer? {
            didSet {
                nativeFrameObservation = layer?.observe(\.contents) { [weak self] layer, _ in
                    guard layer.contents != nil else { return }
                    let deliveredLayer = ObjectIdentifier(layer)
                    MainActor.assumeIsolated {
                        guard let self, self.layer.map(ObjectIdentifier.init) == deliveredLayer,
                              self.core.surface != nil else { return }
                        self.enforceMetalLayerScale()
                        // A synchronous draw still holds Ghostty's renderer lock here.
                        DispatchQueue.main.async { [weak self] in self?.surfaceDidDraw() }
                    }
                }
            }
        }

        // Grouped view state, one struct per concern — same convention as
        // the UIKit twin: each state type is defined in the extension file
        // that owns the behavior (+Input, +Lifecycle); the storage lives
        // here because extensions cannot add stored properties.
        var keyEcho: KeyEchoState = .init()
        var pointer: PointerSelectionState = .init()
        var focusBridge: FocusBridgeState = .init()

        open weak var delegate: (any TerminalSurfaceViewDelegate)? {
            get { core.delegate }
            set { core.delegate = newValue }
        }

        open var controller: TerminalController? {
            get { core.controller }
            set { core.controller = newValue }
        }

        open var configuration: TerminalSurfaceOptions {
            get { core.configuration }
            set { core.configuration = newValue }
        }

        open func setSurfaceVisible(_ visible: Bool) {
            core.setDisplayVisible(visible)
        }

        /// A completed native frame reached the view's layer, not necessarily the screen.
        open func surfaceDidDraw() {}

        /// Adjusts this surface's resize coalescing window without rebuilding
        /// it. Overrides `TerminalSurfaceOptions.resizeThrottleMilliseconds`,
        /// which is the declarative home for the same policy and the one every
        /// platform can reach; pass `nil` to fall back to it.
        open func setResizeThrottle(milliseconds: Double?) {
            core.resizeThrottleInterval = milliseconds.map { max(0, $0) / 1000 }
        }

        public var surface: TerminalSurface? {
            core.surface
        }

        override public init(frame: NSRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func commonInit() {
            wantsLayer = true
            if #available(macOS 14, *) {
                core.makeFrameLink = { [weak self] tick in
                    self.map { WindowFrameLink(view: $0, tick: tick) }
                }
            }

            let metal = CAMetalLayer()
            metal.device = MTLCreateSystemDefaultDevice()
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            metal.isOpaque = false
            metal.backgroundColor = NSColor.clear.cgColor
            layer = metal
            metalLayer = metal
            layer?.backgroundColor = NSColor.clear.cgColor

            inputHandler = TerminalKeyEventHandler(view: self)
            setupTrackingArea()

            core.isAttached = { [weak self] in self?.window != nil }
            core.scaleFactor = { [weak self] in
                Double(
                    self?.window?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor ?? 2.0
                )
            }
            core.viewSize = { [weak self] in
                guard let self else { return (0, 0) }
                return (bounds.width, bounds.height)
            }
            core.platformSetup = { [weak self] config in
                guard let self else { return }
                config.platform_tag = GHOSTTY_PLATFORM_MACOS
                config.platform = ghostty_platform_u(
                    macos: ghostty_platform_macos_s(
                        nsview: Unmanaged.passUnretained(self).toOpaque()
                    )
                )
            }
            core.onMetricsUpdate = { [weak self] in
                self?.updateMetalLayerMetrics()
            }
        }

        // Upstream's rule: Copy is offered whenever ghostty has a selection.
        // A cached drag rect went stale on scroll and select_all, and the
        // quicklook-word test misses whitespace inside a selection.
        open func selectionMenuPoint(at point: CGPoint) -> CGPoint? {
            guard surface?.hasSelection() == true else {
                TerminalDebugLog.log(
                    .input,
                    "selection menu miss point=\(selectionPointDescription(point))"
                )
                return nil
            }

            TerminalDebugLog.log(
                .input,
                "selection menu hit point=\(selectionPointDescription(point))"
            )
            return point
        }

        open func selectionContextMenu() -> NSMenu {
            let menu = NSMenu()
            let copyItem = NSMenuItem(
                title: "Copy",
                action: #selector(copy(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
            menu.addItem(copyItem)
            return menu
        }

        @discardableResult
        open func copySelectedTextToPasteboard() -> Bool {
            guard surface?.hasSelection() == true else {
                return false
            }
            guard surface?.performBindingAction("copy_to_clipboard") == true else {
                return false
            }
            TerminalDebugLog.log(
                .input,
                "selection copied to clipboard"
            )
            return true
        }

        private func selectionPointDescription(_ point: CGPoint) -> String {
            "\(String(format: "%.2f", point.x))x\(String(format: "%.2f", point.y))"
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    /// A terminal's membership in its window's `WindowFrameClock` (`TerminalFrameLink`): resuming
    /// joins the clock of the window the view is in, pausing leaves it.
    @available(macOS 14, *)
    @MainActor
    final class WindowFrameLink: TerminalFrameLink {
        private weak var view: NSView?
        fileprivate let tick: @MainActor () -> Void
        private var clock: WindowFrameClock?

        init(view: NSView, tick: @escaping @MainActor () -> Void) {
            self.view = view
            self.tick = tick
        }

        var isPaused: Bool {
            get { clock == nil }
            set {
                if newValue {
                    clock?.leave(self)
                    clock = nil
                } else if clock == nil, let window = view?.window {
                    let clock = WindowFrameClock.of(window)
                    self.clock = clock
                    clock.join(self)
                }
            }
        }

        func invalidate() {
            isPaused = true
        }
    }

    /// One `NSWindow.displayLink` per window: it follows the window's screen, fires on the main
    /// run loop, and ticks every joined terminal from one callout, so their targeted draws land in
    /// one run-loop pass instead of one link and callout per terminal. Paused while no terminal is
    /// joined, never recreated; the window owns it.
    @available(macOS 14, *)
    @MainActor
    final class WindowFrameClock {
        /// The link retains its target, so the target must not retain the clock.
        @MainActor
        private final class Target: NSObject {
            weak var clock: WindowFrameClock?

            @objc func step(_: CADisplayLink) {
                clock?.step()
            }
        }

        private static var key: UInt8 = 0
        private let link: CADisplayLink
        private var members: [WindowFrameLink] = []
        private var isDraining = false
        /// The drain's next index and end; `leave` shifts both with the array.
        private var cursor = 0
        private var end = 0

        static func of(_ window: NSWindow) -> WindowFrameClock {
            if let clock = objc_getAssociatedObject(window, &key) as? WindowFrameClock {
                return clock
            }
            let clock = WindowFrameClock(window: window)
            objc_setAssociatedObject(window, &key, clock, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return clock
        }

        private init(window: NSWindow) {
            let target = Target()
            let link = window.displayLink(target: target, selector: #selector(Target.step))
            // Match the shared link's cadence for targeted redraws.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            self.link = link
            target.clock = self
        }

        deinit {
            MainActor.assumeIsolated {
                link.invalidate()
            }
        }

        fileprivate func join(_ member: WindowFrameLink) {
            members.append(member)
            link.isPaused = false
        }

        fileprivate func leave(_ member: WindowFrameLink) {
            guard let index = members.firstIndex(where: { $0 === member }) else { return }
            members.remove(at: index)
            if index < end { end -= 1 }
            if index < cursor { cursor -= 1 }
            if members.isEmpty { link.isPaused = true }
        }

        /// Members that join during the drain wait for the next frame; members that leave are
        /// skipped. A nested run loop inside a tick does not restart the drain it interrupted.
        fileprivate func step() {
            guard !isDraining else { return }
            isDraining = true
            cursor = 0
            end = members.count
            while cursor < end {
                let member = members[cursor]
                cursor += 1
                member.tick()
            }
            isDraining = false
        }
    }
#endif
