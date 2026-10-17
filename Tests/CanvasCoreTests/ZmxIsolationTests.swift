import Foundation
import Testing
@testable import CanvasCore

struct ZmxIsolationTests {
    @Test func aDevelopmentHomeIsIsolatedUnderItself() {
        guard case .isolated(let layout) = ZmxIsolation.decide(environment: ["EASL_HOME": "/tmp/easl-dev-plain"], uid: 501, accountHome: "/Users/someone", guiTemp: "/var/folders/ab/T") else {
            Issue.record("a plain development home was refused")
            return
        }
        #expect(layout.zmxDir == "/tmp/easl-dev-plain/zmx")
        #expect(layout.stateHome == "/tmp/easl-dev-plain/state")
        #expect(layout.tmpDir == "/tmp/easl-dev-plain/tmp")
    }

    @Test func noEaslHomeIsTheInstalledApp() {
        let decision = ZmxIsolation.decide(environment: ["HOME": "/Users/twaldin", "TMPDIR": "/var/folders/ab/T/"], uid: 501, accountHome: "/Users/twaldin", guiTemp: "/var/folders/ab/T/")
        #expect(decision == .installed)
    }

    @Test func aSymlinkOutOfTheHomeIsRefused() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-zmx-\(UUID().uuidString.prefix(8))")
        let account = root.appendingPathComponent("account")
        let installed = account.appendingPathComponent(".local/state/zmx")
        let dev = root.appendingPathComponent("dev")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dev.appendingPathComponent("zmx"), withDestinationURL: installed)
        defer { try? FileManager.default.removeItem(at: root) }
        let decision = ZmxIsolation.decide(environment: ["EASL_HOME": dev.path], uid: 501, accountHome: account.path, guiTemp: root.appendingPathComponent("gui").path)
        guard case .refuse(let reason) = decision else {
            Issue.record("symlink into the installed zmx directory was accepted")
            return
        }
        #expect(reason.contains(ZmxIsolation.physical(installed.path)))
    }

    @Test func aSymlinkToAnyOtherDirectoryIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("easl-zmx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dev = root.appendingPathComponent("dev")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dev.appendingPathComponent("tmp"), withDestinationURL: outside)
        let decision = ZmxIsolation.decide(environment: ["EASL_HOME": dev.path], uid: 501, accountHome: root.appendingPathComponent("account").path, guiTemp: nil)
        guard case .refuse = decision else {
            Issue.record("a temporary directory outside the dev home was accepted")
            return
        }
    }

    @Test func dotDotAfterASymlinkStaysInTheLinkTarget() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-phys-\(UUID().uuidString.prefix(8))")
        let target = root.appendingPathComponent("target/nested")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }
        let escaped = root.appendingPathComponent("link/../secret").path
        #expect(ZmxIsolation.physical(escaped) == ZmxIsolation.physical(root.appendingPathComponent("target/secret").path))
    }
}
