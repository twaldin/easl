import CoreGraphics
import Testing
import CanvasCore

struct CanvasWheelTests {
    @Test func directionUsesDominantAxisAndVerticalTies() {
        let cases: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (8, 3, 8, 0), (-8, 3, -8, 0), (3, -8, 0, -8),
            (8, 8, 0, 8), (-8, -8, 0, -8), (0, 0, 0, 0),
            (5, 0, 5, 0), (0, 5, 0, 5)
        ]
        for (dx, dy, x, y) in cases {
            let result = CanvasWheel.direction(dx: dx, dy: dy, precise: true, shift: false)
            #expect(result.dx == x && result.dy == y)
        }
    }

    @Test func shiftRotatesOnlyVerticalLineWheelInput() {
        for precise in [false, true] {
            let vertical = CanvasWheel.direction(dx: 0, dy: -4, precise: precise, shift: true)
            #expect(vertical.dx == (precise ? 0 : -4))
            #expect(vertical.dy == (precise ? -4 : 0))
            let horizontal = CanvasWheel.direction(dx: 8, dy: 2, precise: precise, shift: true)
            #expect(horizontal.dx == 8 && horizontal.dy == 0)
            let diagonal = CanvasWheel.direction(dx: 2, dy: 8, precise: precise, shift: true)
            #expect(diagonal.dx == 0 && diagonal.dy == 8)
            let zero = CanvasWheel.direction(dx: 0, dy: 0, precise: precise, shift: true)
            #expect(zero.dx == 0 && zero.dy == 0)
        }
    }

    @Test func directionalEdgesUseHalfPointTolerance() {
        let cases: [(CGFloat, CGFloat, CGFloat, Bool)] = [
            (0, 100, 1, false), (0.5, 100, 1, false), (0.501, 100, 1, true),
            (0, 100, -1, true), (99.499, 100, -1, true),
            (99.5, 100, -1, false), (100, 100, -1, false),
            (100, 100, 1, true), (50, 100, 0, false),
            (0, 0, -1, false), (0, 0.5, -1, false),
            (0, 0.501, -1, true), (1, -1, 1, false)
        ]
        for (offset, maximum, delta, expected) in cases {
            #expect(CanvasWheel.canScroll(offset: offset, maximum: maximum, delta: delta) == expected)
        }
    }
}
