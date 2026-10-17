import AppKit

/// Keeps terminal tiles' foreground program names (`TerminalTile.program`) current while a
/// board window is on screen. Tiles also refresh on their own events (a title or directory the
/// program reports); this catches programs that report neither (`cargo test`). One timer for
/// every tile, stopped while no window with a terminal is shown, so a minimized or hidden app
/// never wakes for it.
@MainActor
final class TerminalProgramWatch {
    static let shared = TerminalProgramWatch()
    static let interval: TimeInterval = 2

    private let tiles = NSHashTable<TerminalTile>.weakObjects()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func add(_ tile: TerminalTile) {
        tiles.add(tile)
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { TerminalProgramWatch.shared.update() } }
            }
        }
        // Once the tile is in its window.
        DispatchQueue.main.async { self.update() }
    }

    func remove(_ tile: TerminalTile) {
        tiles.remove(tile)
        update()
    }

    private func update() {
        let shown = tiles.allObjects.contains { $0.window.map(Self.shows) == true }
        if shown, timer == nil {
            let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in MainActor.assumeIsolated { TerminalProgramWatch.shared.tick() } }
            timer.tolerance = Self.interval / 2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !shown {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        for tile in tiles.allObjects where tile.window.map(Self.shows) == true { tile.refreshProgram() }
    }

    private static func shows(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
}
