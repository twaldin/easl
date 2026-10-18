import Darwin
import Foundation

extension AppUpdate {
    /// Owns an incoming bundle until it is discarded or its descriptor passes to the helper.
    /// Closing this owner does not unlink the lease or unlock an inherited descriptor.
    public final class StagingLease {
        public private(set) var descriptor: Int32
        private let path: String

        public init(incoming: URL) throws {
            let path = incoming.path + ".lease"
            self.path = path
            let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            descriptor = fd
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let error = POSIXError(.init(rawValue: errno) ?? .EIO)
                try? discard()
                throw error
            }
        }

        deinit {
            if descriptor >= 0 { close(descriptor) }
        }

        /// Only before helper handoff. Never removes another owner's replacement lease.
        public func discard() throws {
            guard descriptor >= 0 else { return }
            let fd = descriptor
            descriptor = -1
            defer { close(fd) }
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            guard lstat(path, &named) == 0 else {
                if errno == ENOENT { return }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard named.st_mode & S_IFMT == S_IFREG, named.st_dev == held.st_dev, named.st_ino == held.st_ino else {
                throw POSIXError(.ESTALE)
            }
            guard unlink(path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }

        /// Holds a separate lock through deletion. An uninspectable lease preserves the entry.
        static func removeLeftover(_ url: URL, protectedBy lease: URL) throws -> Bool {
            let fd = open(lease.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                guard errno == ENOENT else { return false }
                try FileManager.default.removeItem(at: url)
                return true
            }
            defer { close(fd) }
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0, held.st_mode & S_IFMT == S_IFREG,
                  flock(fd, LOCK_EX | LOCK_NB) == 0,
                  lstat(lease.path, &named) == 0, named.st_mode & S_IFMT == S_IFREG,
                  named.st_dev == held.st_dev, named.st_ino == held.st_ino else { return false }
            try FileManager.default.removeItem(at: url)
            return true
        }
    }
}
