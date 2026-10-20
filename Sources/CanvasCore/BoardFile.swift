import Foundation
import Darwin

enum BoardFile {
    struct Unreadable: LocalizedError {
        let filename: String
        let reason: String

        var errorDescription: String? { "Cannot open board \(filename): \(reason)" }
    }

    private struct Header: Decodable {
        var format: Int?
    }

    nonisolated static func read(_ url: URL, backupUnreadable: Bool = true) throws -> BoardSnapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw refusal(url, reason: "unreadable file: \(error.localizedDescription)", data: nil, backup: backupUnreadable)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let header = try decoder.decode(Header.self, from: data)
            if let format = header.format, format > Board.format {
                throw Unreadable(filename: url.path, reason: "requires a newer easl (board format \(format), supported through \(Board.format))")
            }
            return try decoder.decode(BoardSnapshot.self, from: data)
        } catch {
            let reason = (error as? Unreadable)?.reason ?? "unreadable board data: \(String(describing: error))"
            throw refusal(url, reason: reason, data: data, backup: backupUnreadable)
        }
    }

    nonisolated private static func refusal(_ url: URL, reason: String, data: Data?, backup: Bool) -> Unreadable {
        var reason = reason
        if backup {
            do { try preserve(url, data: data) }
            catch { reason += "; could not preserve unreadable copy: \(error.localizedDescription)" }
        }
        return Unreadable(filename: url.path, reason: reason)
    }

    nonisolated private static func preserve(_ url: URL, data: Data?) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".unreadable-"
        let bytes = try data ?? Data(contentsOf: url)
        let siblings = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for sibling in siblings where sibling.lastPathComponent.hasPrefix(prefix) {
            if let saved = try? Data(contentsOf: sibling), saved == bytes { return }
        }
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
        let timestamp = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), modified.timeIntervalSince1970)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).unreadable-copy")
        try bytes.write(to: temporary, options: .withoutOverwriting)
        defer { try? manager.removeItem(at: temporary) }
        var collision = 0
        while true {
            let suffix = collision == 0 ? "" : "-\(collision)"
            let copy = directory.appendingPathComponent(prefix + timestamp + suffix)
            if Darwin.link(temporary.path, copy.path) == 0 { return }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            if let saved = try? Data(contentsOf: copy), saved == bytes { return }
            collision += 1
        }
    }
}
