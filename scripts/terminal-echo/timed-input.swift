import Foundation
import Darwin

let arguments = CommandLine.arguments
if arguments.count != 2 {
    FileHandle.standardError.write(Data("usage: timed-input '<JSON object with string values>'\n".utf8))
    exit(2)
}
let fields: [String: String]
do {
    guard let data = arguments[1].data(using: .utf8),
          let value = try JSONSerialization.jsonObject(with: data) as? [String: String],
          let pid = value["pid"], Int(pid) != nil, value["kind"] != nil else {
        throw NSError(domain: "timed-input", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected string-valued pid and kind fields"])
    }
    fields = value
} catch {
    FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    exit(2)
}
var base = mach_timebase_info_data_t()
guard mach_timebase_info(&base) == KERN_SUCCESS, base.numer != 0, base.denom != 0 else {
    FileHandle.standardError.write(Data("Cannot read mach timebase\n".utf8))
    exit(1)
}
let center = DistributedNotificationCenter.default()
let name = Notification.Name("canvas.dev.input")
let stamp = Double(mach_absolute_time()) * Double(base.numer) / Double(base.denom) / 1_000_000
print(String(format: "%.6f", stamp))
fflush(stdout)
center.postNotificationName(name, object: nil, userInfo: fields, deliverImmediately: true)
usleep(150_000)
