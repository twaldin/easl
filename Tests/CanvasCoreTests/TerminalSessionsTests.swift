import Foundation
import Testing
import CanvasCore

struct TerminalSessionsTests {
    @Test func zmxLabelLessTimeoutRemainsListedWithoutRunning() {
        let sessions = TerminalSessions.zmx("  name=canvas-obj_01M5AJE4R2C4MP50ZN\terr=Timeout\tstatus=unreachable\n", home: "home", legacy: []) { _ in nil }
        #expect(sessions.running.isEmpty)
        #expect(sessions.unverified == ["obj_01M5AJE4R2C4MP50ZN"])
    }

    @Test func zmxOwnedAndLegacyHomesAreRunning() {
        let output = """
        → name=canvas-obj_current\tpid=2811\tclients=0\tcanvas.home=home\tcanvas.tile=obj_current\tcanvas.board=brd_current
        *name=canvas-obj_legacy\tpid=42\tcanvas.home=old-home\tcanvas.tile=obj_legacy\tcanvas.board=brd_old
          name=canvas-obj_prompt\tpid=77\tcanvas.home=home\tcanvas.tile=obj_prompt
        """
        let sessions = TerminalSessions.zmx(output, home: "home", legacy: ["old-home"]) { _ in nil }
        #expect(Set(sessions.running.keys) == ["obj_current", "obj_legacy", "obj_prompt"])
    }

    @Test func zmxOwnershipAndReachabilityFailuresDoNotBecomeRunning() {
        let output = """
        name=canvas-obj_foreign\tcanvas.home=other\tcanvas.tile=obj_foreign
        name=canvas-obj_mismatch\tcanvas.home=home\tcanvas.tile=obj_other
        name=canvas-obj_unlabelled\tpid=12
        name=canvas-obj_error\terr=Timeout\tcanvas.home=home\tcanvas.tile=obj_error
        name=canvas-obj_unreachable\tstatus=unreachable\tcanvas.home=home\tcanvas.tile=obj_unreachable
        name=user-session\tcanvas.home=home\tcanvas.tile=obj_injected
        """
        let sessions = TerminalSessions.zmx(output, home: "home", legacy: []) { _ in nil }
        #expect(sessions.running.isEmpty)
        #expect(sessions.unverified == ["obj_foreign", "obj_mismatch", "obj_unlabelled", "obj_error", "obj_unreachable"])
    }

    @Test func zmxCleaningUpNamesAreAbsent() {
        let output = "name=canvas-obj_gone\terr=Connection refused\tstatus=cleaning up\tcanvas.home=home\tcanvas.tile=obj_gone\n"
        let sessions = TerminalSessions.zmx(output, home: "home", legacy: []) { _ in nil }
        #expect(!sessions.lists("obj_gone"))
    }

    @Test func hostedWireTimeoutRemainsListedWithoutRunning() throws {
        let entries = try JSONDecoder().decode([JSONValue].self, from: Data(#"[{"session":"canvas-obj_busy","tile":"obj_busy","labels":{},"unreachable":true}]"#.utf8))
        let sessions = TerminalSessions.hosted(entries, home: "home")
        #expect(sessions.running.isEmpty)
        #expect(sessions.unverified == ["obj_busy"])
    }

    @Test func hostedOwnedSessionsExcludeRemotePIDs() throws {
        let entries = try JSONDecoder().decode([JSONValue].self, from: Data(#"[{"session":"canvas-obj_owned","tile":"obj_owned","labels":{"canvas.home":"home","canvas.tile":"obj_owned","canvas.board":"brd_remote"},"pid":2811,"clients":1}]"#.utf8))
        let sessions = TerminalSessions.hosted(entries, home: "home")
        #expect(Set(sessions.running.keys) == ["obj_owned"])
        #expect(try #require(sessions.running["obj_owned"]).pid == nil)
    }

    @Test func hostedOwnershipBoundariesAndCleaningUpNames() throws {
        let wire = #"""
        [
          {"session":"canvas-obj_foreign","tile":"obj_foreign","labels":{"canvas.home":"other","canvas.tile":"obj_foreign"}},
          {"session":"canvas-obj_mismatch","tile":"obj_mismatch","labels":{"canvas.home":"home","canvas.tile":"obj_other"}},
          {"session":"canvas-obj_wrongwire","tile":"obj_other","labels":{"canvas.home":"home","canvas.tile":"obj_wrongwire"}},
          {"session":"canvas-obj_unlabelled","tile":"obj_unlabelled","labels":{}},
          {"session":"canvas-obj_busy","tile":"obj_busy","labels":{"canvas.home":"home","canvas.tile":"obj_busy"},"unreachable":true},
          {"session":"canvas-obj_gone","tile":"obj_gone","labels":{},"status":"cleaning up"},
          {"session":"user-session","tile":"obj_injected","labels":{"canvas.home":"home","canvas.tile":"obj_injected"}}
        ]
        """#
        let entries = try JSONDecoder().decode([JSONValue].self, from: Data(wire.utf8))
        let sessions = TerminalSessions.hosted(entries, home: "home")
        #expect(sessions.running.isEmpty)
        #expect(sessions.unverified == ["obj_foreign", "obj_mismatch", "obj_wrongwire", "obj_unlabelled", "obj_busy"])
    }
}
