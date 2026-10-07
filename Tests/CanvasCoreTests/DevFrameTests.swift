import CoreGraphics
import Testing
import CanvasCore

struct DevFrameTests {
    @Test func fourFiniteNumbersWithAPositiveSizeAreAFrame() {
        #expect(DevFrame.parse("1522 -972 1492 922") == CGRect(x: 1522, y: -972, width: 1492, height: 922))
        #expect(DevFrame.parse("  10.5\t-20 300 200 ") == CGRect(x: 10.5, y: -20, width: 300, height: 200))
    }

    @Test func anythingElseIsNoFrame() {
        #expect(DevFrame.parse("") == nil)
        #expect(DevFrame.parse("1 2 3") == nil, "three numbers")
        #expect(DevFrame.parse("1 2 3 4 5") == nil, "five numbers")
        #expect(DevFrame.parse("1 2 x 4") == nil, "a word among them")
        #expect(DevFrame.parse("1 2 3 4 junk") == nil, "junk is not dropped")
        #expect(DevFrame.parse("1 2 nan 4") == nil)
        #expect(DevFrame.parse("1 2 3 inf") == nil)
        #expect(DevFrame.parse("1 2 0 4") == nil, "no width")
        #expect(DevFrame.parse("1 2 3 -4") == nil, "negative height")
    }
}
