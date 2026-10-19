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

}
