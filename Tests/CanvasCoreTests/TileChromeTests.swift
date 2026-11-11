import Foundation
import Testing
import CanvasCore

struct TileChromeTests {
    static let types: [ObjectType] = [.terminal, .browser, .note, .code, .html, .image, .video, .diagram, .question, .changes]
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func object(_ type: ObjectType, lifecycle: JSONValue? = nil, props: [String: JSONValue] = [:]) -> CanvasObject {
        var props = props
        props["lifecycle"] = lifecycle
        return CanvasObject(id: "tile", type: type, frame: Frame(x: 0, y: 0, w: 352, h: 232), z: 0,
                            createdBy: .agent(tile: "creator"), createdAt: now, props: .object(props))
    }

    @Test(arguments: types)
    func typingIsOnlyTheKeyboardHolder(_ type: ObjectType) {
        let tile = object(type, lifecycle: .object(["state": .string("working")]))
        #expect(TileChromeState(object: tile, focused: tile.id).typing)
        #expect(!TileChromeState(object: tile, focused: "creator").typing)
        #expect(!TileChromeState(object: tile, focused: nil).typing)
    }

    @Test(arguments: types)
    func lifecycleAndErrorsAreTerminalOnly(_ type: ObjectType) {
        let states: [(String, ChromeRole)] = [("working", .working), ("idle", .idle), ("blocked", .blocked), ("done", .done)]
        for (state, role) in states {
            let tile = object(type, lifecycle: .object(["state": .string(state), "message": .string("reported detail")]))
            let shown = TileChromeState(object: tile, focused: tile.id)
            #expect(shown.typing)
            #expect(shown.terminal?.text == (type == .terminal ? state : nil))
            #expect(shown.terminal?.role == (type == .terminal ? role : nil))
            #expect(shown.terminal?.detail == (type == .terminal ? "reported detail" : nil))
        }
        let failed = object(type, lifecycle: .object(["state": .string("working"), "error": .string("agent failed")]))
        #expect(TileChromeState(object: failed, focused: nil).terminal?.role == (type == .terminal ? .error : nil))
        #expect(TileChromeState(object: failed, focused: nil).terminal?.detail == (type == .terminal ? "agent failed" : nil))
        let command = TileChromeState.Command(text: "exit 1", failed: true, detail: "swift test exited 1")
        let shown = TileChromeState(object: object(type), focused: "tile", command: command)
        #expect(shown.terminal?.text == (type == .terminal ? "error" : nil))
        #expect(shown.terminal?.detail == (type == .terminal ? command.detail : nil))
        #expect(shown.typing)
        let duration = TileChromeState.Command(text: "2.1s", detail: "successful command")
        #expect(TileChromeState(object: object(type), focused: nil, command: duration).terminal?.text == (type == .terminal ? "2.1s" : nil))
    }

    @Test(arguments: types)
    func missingAndUnknownAreNeutral(_ type: ObjectType) {
        let lifecycles: [JSONValue?] = [nil, .object([:]), .object(["state": .string("unknown")]), .object(["state": .string("invented")])]
        for lifecycle in lifecycles {
            let shown = TileChromeState(object: object(type, lifecycle: lifecycle), focused: nil)
            #expect(!shown.typing)
            #expect(shown.terminal == nil)
        }
    }

    @Test(arguments: types)
    func needsYouUsesClassifierReasonsOnEveryType(_ type: ObjectType) {
        let markerMessage = "Inspect release candidate Ω\nPreserve every line and trailing detail."
        let lifecycleMessage = "Approve the deployment?\nKeep build artifacts until review finishes."
        let questionMessage = "Which release should ship?\nChoose stable, preview, or neither."
        func items(_ tile: CanvasObject, marked: Bool = false) -> [NeedsYouItem] {
            NeedsYouItem.all([tile.id: tile], attention: marked ? [tile.id: Attention(object: tile.id, message: markerMessage, raisedBy: "creator", raisedAt: now)] : [:], now: now)
        }
        let closedQuestion: [String: JSONValue] = ["status": .string("answered")]
        let neutral = object(type, props: closedQuestion)
        #expect(items(neutral).isEmpty)
        let marked = items(neutral, marked: true)
        #expect(marked.first?.reason == .marked)
        #expect(marked.first.map(TileChromeState.needsYouText)?.contains(markerMessage) == true)
        for state in ["blocked", "done"] {
            let tile = object(type, lifecycle: .object(["state": .string(state), "message": .string(lifecycleMessage)]), props: closedQuestion)
            let needs = items(tile)
            #expect(needs.first?.reason == (type == .terminal ? (state == "blocked" ? .blocked : .done) : nil))
            if let item = needs.first {
                #expect(TileChromeState.needsYouText(item).contains(lifecycleMessage))
            }
        }
        let question = object(type, props: ["question": .string(questionMessage)])
        #expect(items(question).first?.reason == (type == .question ? .question : nil))
        if let item = items(question).first { #expect(TileChromeState.needsYouText(item).contains(questionMessage)) }
        let seen = object(type, lifecycle: .object(["state": .string("done"), "seen": .bool(true)]), props: closedQuestion)
        #expect(items(seen).isEmpty)
    }

    @Test func classifierPrecedenceAndFullReasonSurvive() {
        let message = "Approve command?\nrm build"
        let tile = object(.terminal, lifecycle: .object(["state": .string("blocked"), "message": .string(message)]))
        let marker = Attention(object: tile.id, message: "other reason", raisedBy: nil, raisedAt: now)
        let items = NeedsYouItem.all([tile.id: tile], attention: [tile.id: marker], now: now)
        #expect(items.count == 1)
        #expect(items.first?.reason == .blocked)
        #expect(items.first.map(TileChromeState.needsYouText)?.contains(message) == true)
        let expired = object(.question, props: ["expiresAt": .string("2020-01-01T00:00:00Z")])
        #expect(NeedsYouItem.all([expired.id: expired], attention: [:], now: now).isEmpty)
    }
}
