import Foundation
import Testing
@testable import CanvasCore

struct ZmxIsolationTests {
    @Test func aDevelopmentHomeIsIsolatedUnderItself() throws {
        let home = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-zmx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        guard case .isolated(let layout) = ZmxIsolation.decide(environment: ["EASL_HOME": home.path], uid: 501, accountHome: "/Users/someone", guiTemp: "/var/folders/ab/T") else {
            Issue.record("a plain development home was refused")
            return
        }
        #expect(layout.zmxDir == home.path + "/zmx")
        #expect(layout.stateHome == home.path + "/state")
        #expect(layout.tmpDir == home.path + "/tmp")
    }

    @Test func noEaslHomeIsTheInstalledApp() {
        let decision = ZmxIsolation.decide(environment: ["HOME": "/Users/twaldin", "TMPDIR": "/var/folders/ab/T/"], uid: 501, accountHome: "/Users/twaldin", guiTemp: "/var/folders/ab/T/")
        #expect(decision == .installed)
    }

    @Test func aSymlinkOutOfTheHomeIsRefused() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-zmx-\(UUID().uuidString)")
        let account = root.appendingPathComponent("account")
        let installed = account.appendingPathComponent(".local/state/zmx")
        let dev = root.appendingPathComponent("dev")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dev.appendingPathComponent("zmx"), withDestinationURL: installed)
        defer { try? FileManager.default.removeItem(at: root) }
        let decision = ZmxIsolation.decide(environment: ["EASL_HOME": dev.path], uid: 501, accountHome: account.path, guiTemp: root.appendingPathComponent("gui").path)
        guard case .refuse = decision else {
            Issue.record("symlink into the installed zmx directory was accepted")
            return
        }
    }

    @Test func aSymlinkToAnyOtherDirectoryIsRefused() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-zmx-\(UUID().uuidString)")
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
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-phys-\(UUID().uuidString)")
        let target = root.appendingPathComponent("target/nested")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }
        let escaped = root.appendingPathComponent("link/../secret").path
        let real = try #require(realpath(root.path, nil))
        defer { free(real) }
        #expect(try ZmxIsolation.physical(escaped) == String(cString: real) + "/target/secret")
    }

    @Test func aDanglingSymlinkCannotEscapeTheDevelopmentHome() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-zmx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dev = root.appendingPathComponent("dev")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dev.appendingPathComponent("zmx"), withDestinationURL: root.appendingPathComponent("outside/missing"))
        let decision = ZmxIsolation.decide(environment: ["EASL_HOME": dev.path], uid: 501, accountHome: root.appendingPathComponent("account").path, guiTemp: nil)
        guard case .refuse = decision else {
            Issue.record("a dangling zmx symlink outside the development home was accepted")
            return
        }
    }

    @Test func aSymlinkCycleIsRefusedInsteadOfRecursingIndefinitely() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-zmx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("zmx").path, withDestinationPath: "zmx")
        let decision = ZmxIsolation.decide(environment: ["EASL_HOME": root.path], uid: 501, accountHome: root.appendingPathComponent("account").path, guiTemp: nil)
        guard case .refuse = decision else {
            Issue.record("a cyclic zmx path was accepted")
            return
        }
    }

    @Test func theSocketPathLimitCountsUtf8Bytes() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-zmx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.path + "/"
        let valid = prefix + String(repeating: "x", count: 69 - prefix.utf8.count)
        let options = (uid: UInt32(501), accountHome: root.appendingPathComponent("account").path)
        guard case .isolated = ZmxIsolation.decide(environment: ["EASL_HOME": valid], uid: options.uid, accountHome: options.accountHome, guiTemp: nil) else {
            Issue.record("a home fitting the zmx socket limit was refused")
            return
        }
        let invalid = String(valid.dropLast()) + "é"
        guard case .refuse = ZmxIsolation.decide(environment: ["EASL_HOME": invalid], uid: options.uid, accountHome: options.accountHome, guiTemp: nil) else {
            Issue.record("a home exceeding the zmx socket limit was accepted")
            return
        }
    }
}
