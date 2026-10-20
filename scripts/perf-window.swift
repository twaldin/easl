import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Vision

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "--help" {
    print("Usage: perf-window PID | --drawn PNG | --activate PID\nPID lists the owned application's on-screen windows.\n--drawn recognizes fixture terminal output in an image.\n--activate records and activates only a PID inside a VirtualMac guest; it refuses physical Macs.")
    exit(0)
}
let output: Any
if arguments.count == 3, arguments[1] == "--activate" {
    var bytes = [UInt8](repeating: 0, count: 128)
    var size = bytes.count
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
        throw CocoaError(.featureUnsupported)
    }
    let model = String(decoding: bytes.prefix(max(0, size - 1)), as: UTF8.self)
    guard model.hasPrefix("VirtualMac") else {
        fputs("Activation is restricted to a VirtualMac GUI guest; this host is " + model + "\n", stderr)
        exit(64)
    }
    guard let pid = Int32(arguments[2]), let application = NSRunningApplication(processIdentifier: pid) else {
        throw CocoaError(.executableNotLoadable)
    }
    let before = application.isActive
    let activated = application.activate(options: [])
    let deadline = Date().addingTimeInterval(5)
    while !application.isActive && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    output = ["pid": pid, "model": model, "activeBefore": before, "activateResult": activated,
              "isActive": application.isActive, "time": Date().timeIntervalSince1970]
} else if arguments.count == 3, arguments[1] == "--drawn" {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.005
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let marker = try NSRegularExpression(pattern: #"sequence\s*=.*status\s*=\s*running\b"#, options: .caseInsensitive)
    let drawn = lines.contains {
        marker.rangeOfFirstMatch(in: $0, range: NSRange($0.startIndex..<$0.endIndex, in: $0)).location != NSNotFound
    }
    output = ["drawn": drawn, "lines": lines]
} else if arguments.count == 2, let pid = Int(arguments[1]) {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    output = windows.filter {
        ($0[kCGWindowOwnerPID as String] as? Int) == pid
            && ($0[kCGWindowLayer as String] as? Int) == 0
    }
} else {
    throw CocoaError(.validationMissingMandatoryProperty)
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
