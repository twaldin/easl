import CoreGraphics

/// A window's device pixels. Content drawn outside AppKit (a terminal's Metal surface) that sits
/// between them is resampled when the window is composited, which blurs text, on a 1x screen most
/// of all; easl moves such content onto the nearest pixel in window space (`TerminalTile.alignToPixels`).
public enum PixelGrid {
    /// `point` (window points) on the nearest device pixel, at `pixelsPerPoint` (the window's
    /// backing scale). Depends on nothing but its arguments, so a jump or a change of screen
    /// lands where a fresh call would.
    public static func nearest(_ point: CGPoint, pixelsPerPoint: CGFloat) -> CGPoint {
        guard pixelsPerPoint > 0 else { return point }
        return CGPoint(x: (point.x * pixelsPerPoint).rounded() / pixelsPerPoint, y: (point.y * pixelsPerPoint).rounded() / pixelsPerPoint)
    }
}
