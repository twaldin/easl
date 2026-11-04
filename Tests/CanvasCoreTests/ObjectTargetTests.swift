import Foundation
import Testing
@testable import CanvasCore

struct ObjectTargetTests {
    @Test func bridgeRequiresExactlyOneTargetAndNoOptions() throws {
        #expect(try HtmlMessage.parse(.object(["type": "object.goTo", "id": "obj_a"])) == .goTo(.id("obj_a")))
        #expect(try HtmlMessage.parse(.object(["type": "object.goTo", "key": "Plan / α"])) == .goTo(.key("Plan / α")))
        let invalid: [[String: JSONValue]] = [[:], ["id": "a", "key": "b"], ["id": .null], ["id": ""], ["id": "a", "zoom": 1], ["key": "a", "extra": .bool(true)]]
        for fields in invalid {
            var message = fields
            message["type"] = "object.goTo"
            #expect(throws: HtmlError.self) { try HtmlMessage.parse(.object(message)) }
        }
    }

    @Test func reservedURLsRoundTripAndRejectMalformedTargets() {
        for target in [ObjectTarget.id("obj_a/b?#% α"), .key("Plan / α")] {
            #expect(ObjectTarget(encoded: target.encoded) == target)
        }
        for url in ["easl:object/", "easl:key/", "easl:object/a/b", "easl:object/a?zoom=1", "easl:key/a#b", "easl:object/%GG", "easl:object/%00", "easl://object/a"] {
            #expect(ObjectTarget(encoded: url) == nil)
        }
    }

    @Test func onlyClicksAndEnterAuthorizeNavigationAndAllConsumesAreOneShot() {
        for gesture in [HtmlGesturePermit.Gesture.click, .enter, .otherKey] {
            var permit = HtmlGesturePermit(url: "page")
            permit.arm(at: 10, gesture: gesture)
            #expect(permit.consume(at: 11, forNavigation: true) == (gesture != .otherKey))
            #expect(permit.consume(at: 11) == false)
            permit.arm(at: 10, gesture: gesture)
            #expect(permit.consume(at: 11) == true)
        }
    }

    @MainActor @Test func resolvesOnlyVisibleTargetsOnTheSourceBoard() throws {
        let board = Board(id: "brd_test", root: URL(fileURLWithPath: "/tmp"))
        let source = board.create(type: .html, props: .object(["html": "hello"]))
        let target = board.create(type: .note, props: .object(["markdown": "plan", "key": "plan"]))
        #expect(try ObjectTarget.key("plan").resolve(on: board, from: source.id) == target.id)
        #expect(try ObjectTarget.id(target.id).resolve(on: board, from: source.id) == target.id)
        let other = Board(id: "brd_other", root: URL(fileURLWithPath: "/tmp"))
        let foreign = other.create(type: .note, props: .object(["markdown": "other"]))
        #expect(throws: HtmlError.self) { try ObjectTarget.id(foreign.id).resolve(on: board, from: source.id) }
        #expect(throws: HtmlError.self) { try ObjectTarget.key("missing").resolve(on: board, from: source.id) }
        #expect(throws: HtmlError.self) { try ObjectTarget.id(target.id).resolve(on: board, from: foreign.id) }
        let hidden = board.create(type: .question, props: .object(["archived": .bool(true)]))
        #expect(throws: HtmlError.unavailable("target object is hidden")) { try ObjectTarget.id(hidden.id).resolve(on: board, from: source.id) }
        board.deactivate()
        #expect(throws: HtmlError.unavailable("host closed this board")) { try ObjectTarget.key("plan").resolve(on: board, from: source.id) }
    }
}

#if canImport(AppKit)
struct NoteObjectLinkTests {
    @Test func objectLinksRoundTripWithoutExternalFallback() {
        for target in [ObjectTarget.id("obj_a/b% α"), .key("Plan / α")] {
            #expect(NoteLink(encoded: NoteLink.object(target).encoded) == .object(target))
        }
        for url in ["easl:object/", "easl:key/a/b", "easl:object/a?zoom=1", "easl:object/%GG", "easl://object/a", "EASL:object/a"] {
            #expect(NoteLink(encoded: url) == nil)
        }
    }
}
#endif
