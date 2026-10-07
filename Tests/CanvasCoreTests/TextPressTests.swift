import Foundation
import Testing
import CanvasCore

/// A press in a question tile's text: a click on a link follows it, a drag selects (from a link
/// too), ⇧ extends, and a selection never cuts a character in two.
struct TextPressTests {
    let text = "Open http://127.0.0.1:8123/x?y today"
    var link: WebLink.Match { WebLink.matches(in: text)[0] }

    @Test func aClickOnALinkFollowsItThroughATremor() {
        var press = TextPress(at: CGPoint(x: 100, y: 40), offset: 8, on: link)
        #expect(press.move(to: CGPoint(x: 102, y: 42), offset: 8, in: text) == nil, "under the drag distance")
        #expect(press.follows == link)
        #expect(TextPress(at: .zero, offset: 1, on: nil).follows == nil, "off a link, a click follows nothing")
    }

    @Test func aDragFromALinkSelectsInsteadOfFollowingIt() {
        var press = TextPress(at: CGPoint(x: 100, y: 40), offset: 5, on: link)
        #expect(press.move(to: CGPoint(x: 100 + TextPress.dragDistance, y: 40), offset: 12, in: text) == NSRange(location: 5, length: 7))
        #expect(press.follows == nil)
        // Once a drag, back over where it went down: a drag still, selecting nothing.
        #expect(press.move(to: CGPoint(x: 100, y: 40), offset: 5, in: text) == NSRange(location: 5, length: 0))
        #expect(press.dragging && press.follows == nil)
    }

    @Test func aDragBackwardSelectsUpToWhereItWentDown() {
        var press = TextPress(at: CGPoint(x: 300, y: 40), offset: 30, on: nil)
        let range = press.move(to: CGPoint(x: 20, y: 40), offset: 5, in: text)
        #expect(range == NSRange(location: 5, length: 25))
        #expect(range.map { (text as NSString).substring(with: $0) } == "http://127.0.0.1:8123/x?y")
    }

    @Test func aShiftPressExtendsTheSelectionFromItsFarEnd() {
        let selected = NSRange(location: 5, length: 5)
        var before = TextPress(at: .zero, offset: 2, on: link, extending: selected)
        #expect(before.anchor == 10 && before.dragging && before.link == nil)
        #expect(before.move(to: .zero, offset: 2, in: text) == NSRange(location: 2, length: 8), "at once, with no drag")
        var after = TextPress(at: .zero, offset: 14, on: nil, extending: selected)
        #expect(after.move(to: .zero, offset: 14, in: text) == NSRange(location: 5, length: 9))
        #expect(TextPress(at: .zero, offset: 2, on: nil, extending: NSRange(location: 5, length: 0)).dragging == false, "nothing selected: a plain press")
    }

    @Test func aSelectionTakesWholeCharactersAndStaysInTheText() {
        #expect(TextPress.range(from: 0, to: 2, in: "a😀b") == NSRange(location: 0, length: 3), "the emoji's second half comes along")
        #expect(TextPress.range(from: 4, to: 2, in: "a😀b") == NSRange(location: 1, length: 3))
        #expect(TextPress.range(from: 0, to: 4, in: "cafe\u{301}!") == NSRange(location: 0, length: 5), "the accent stays on its letter")
        #expect(TextPress.range(from: -3, to: 99, in: "abc") == NSRange(location: 0, length: 3))
        #expect(TextPress.range(from: 2, to: 2, in: "abc").length == 0)
    }
}
