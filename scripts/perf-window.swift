import CoreGraphics
import Foundation
import ImageIO
import Vision

let arguments = CommandLine.arguments
let output: Any
if arguments.count == 3, arguments[1] == "--drawn" {
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
} else {
    let pid = Int(arguments[1])!
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    output = windows.filter {
        ($0[kCGWindowOwnerPID as String] as? Int) == pid
            && ($0[kCGWindowLayer as String] as? Int) == 0
    }
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
