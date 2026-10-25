import Darwin
import Foundation

public enum Run6Trace {
    public nonisolated static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    public nonisolated static func id(_ object: AnyObject?) -> String {
        guard let object else { return "none" }
        return String(ObjectIdentifier(object).hashValue, radix: 16)
    }

    public nonisolated static func event(_ event: StaticString, _ fields: String = "") {
        let mono = now()
        let wall = Date().timeIntervalSince1970
        var usage = rusage()
        let status = getrusage(RUSAGE_SELF, &usage)
        let cpu = status == 0 ?
            (Int64(usage.ru_utime.tv_sec) + Int64(usage.ru_stime.tv_sec)) * 1_000_000 +
                Int64(usage.ru_utime.tv_usec) + Int64(usage.ru_stime.tv_usec) : -1
        emit("RUN6_TRACE mono_ns=\(mono) wall_s=\(wall) pid=\(getpid()) ppid=\(getppid()) cpu_self_us=\(cpu) event=\(event) \(fields)")
    }

    public nonisolated static func emit(_ line: String) {
        let record = line + "\n"
        let count = record.utf8.count
        record.withCString { bytes in
            _ = Darwin.write(STDERR_FILENO, bytes, count)
        }
    }
}
