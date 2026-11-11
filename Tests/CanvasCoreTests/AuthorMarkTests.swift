import Foundation
import Testing
import CanvasCore

struct AuthorMarkTests {
    func object(_ id: ObjectID, _ type: ObjectType, by actor: Actor, _ props: [String: JSONValue] = [:]) -> CanvasObject {
        CanvasObject(id: id, type: type, frame: Frame(x: 0, y: 0, w: 100, h: 100), z: 0, createdBy: actor, createdAt: Date(), props: .object(props))
    }

    @Test func agentObjectsNameTheirTerminalAndNothingElseDoes() {
        let named = object("named", .terminal, by: .user, ["name": .string("B ssrSafe"), "agent": .object(["kind": .string("omp")])])
        let unnamed = object("unnamed", .terminal, by: .user, ["agent": .object(["kind": .string("codex")])])
        let objects = Dictionary(uniqueKeysWithValues: [
            named, unnamed,
            object("review", .note, by: .agent(tile: "named")),
            object("explainer", .html, by: .agent(tile: "unnamed")),
            object("lane", .group, by: .agent(tile: "named")),
            object("mine", .note, by: .user),
            object("follow", .code, by: .agent(tile: "named"), ["followOf": .string("named")]),
            object("shell", .terminal, by: .agent(tile: "named")),
            object("orphan", .note, by: .agent(tile: "closed")),
        ].map { ($0.id, $0) })
        func name(_ id: ObjectID, program: String? = nil) -> String? {
            AuthorMark.name(of: objects[id]!, in: objects) { _ in program }
        }
        #expect(name("review") == "B ssrSafe")
        #expect(name("review", program: "omp") == "B ssrSafe", "the terminal's name before its program")
        #expect(name("lane") == "B ssrSafe")
        #expect(name("explainer", program: "codex exec") == "codex exec", "no name: the program in its foreground")
        #expect(name("explainer") == "codex", "at the prompt: the agent kind")
        #expect(name("mine") == "you")
        #expect(name("follow") == nil, "a follow tile belongs visibly to its terminal")
        #expect(name("shell") == nil, "terminals carry none")
        #expect(name("orphan") == nil, "the author terminal is gone")
        #expect(AuthorMark.name(of: object("bare", .terminal, by: .user, ["name": .string("  ")]), program: nil) == "Terminal")
    }

    @Test func snapshotsOverrideLiveResolutionForEveryObjectKind() {
        for type in ObjectType.allCases {
            var captured = object("captured", type, by: .agent(tile: "gone"), ["followOf": "gone"])
            captured.authorName = "Creation name"
            #expect(AuthorMark.name(of: captured, in: [:]) { _ in "renamed" } == "Creation name")
        }
        var user = object("mine", .note, by: .user)
        user.authorName = "captured"
        #expect(AuthorMark.name(of: user, in: [:]) { _ in nil } == "you")
    }

}
