import CoreGraphics
import Testing
import CanvasCore

/// Where a terminal's surface lands in window space (`PixelGrid`), so its text isn't resampled.
struct PixelGridTests {
    @Test func aPointMovesToTheNearestDevicePixel() {
        #expect(PixelGrid.nearest(CGPoint(x: 198.625, y: -258.59), pixelsPerPoint: 1) == CGPoint(x: 199, y: -259), "a 1x screen has whole points")
        #expect(PixelGrid.nearest(CGPoint(x: 10.3, y: 10.8), pixelsPerPoint: 2) == CGPoint(x: 10.5, y: 11), "Retina has half points")
        #expect(PixelGrid.nearest(CGPoint(x: 10.3, y: 0), pixelsPerPoint: 0) == CGPoint(x: 10.3, y: 0), "no scale leaves the point alone")
    }

    @Test func aPointOnAPixelStays() {
        #expect(PixelGrid.nearest(CGPoint(x: 42, y: -7), pixelsPerPoint: 1) == CGPoint(x: 42, y: -7))
        #expect(PixelGrid.nearest(CGPoint(x: 198.5, y: 3.5), pixelsPerPoint: 2) == CGPoint(x: 198.5, y: 3.5), "a .5 origin is already on a Retina pixel")
    }

    @Test func aJumpFromARestLandsOnItsOwnNearestPixel() {
        // At rest on a pixel, then a jump (a reveal, Back, a restored view) to a fractional point:
        // nothing of the rest carries over.
        let rest = PixelGrid.nearest(CGPoint(x: 10.4, y: 0), pixelsPerPoint: 1)
        #expect(rest == CGPoint(x: 10, y: 0))
        #expect(PixelGrid.nearest(CGPoint(x: 500.3, y: 7.7), pixelsPerPoint: 1) == CGPoint(x: 500, y: 8))
        #expect(PixelGrid.nearest(CGPoint(x: rest.x + 0.4, y: 0), pixelsPerPoint: 1) == rest, "a step under half a pixel stays put")
    }

    @Test func theSamePointFollowsAChangeOfScale() {
        // The window moved from a 1x to a Retina screen, and back.
        let point = CGPoint(x: 120.375, y: 64.7)
        #expect(PixelGrid.nearest(point, pixelsPerPoint: 1) == CGPoint(x: 120, y: 65))
        #expect(PixelGrid.nearest(point, pixelsPerPoint: 2) == CGPoint(x: 120.5, y: 64.5))
        #expect(PixelGrid.nearest(point, pixelsPerPoint: 1) == CGPoint(x: 120, y: 65))
    }
}
