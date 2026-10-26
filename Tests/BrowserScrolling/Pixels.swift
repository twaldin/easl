import AppKit
import Foundation

struct Samples: Decodable {
    let contentTop: Double
    let scale: Double
    let points: [[Double]]
}

enum PixelError: Error {
    case invalidArguments
    case invalidImage
    case invalidGeometry
    case unreadableSample(Int, Int)
}

guard CommandLine.arguments.count == 2 else {
    throw PixelError.invalidArguments
}
let samples = try JSONDecoder().decode(Samples.self, from: FileHandle.standardInput.readDataToEndOfFile())
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
    throw PixelError.invalidImage
}
guard samples.contentTop.isFinite, samples.contentTop >= 0,
      samples.scale.isFinite, samples.scale > 0 else {
    throw PixelError.invalidGeometry
}
let scale = samples.scale
let offsetY = samples.contentTop * scale
let colors: [[Int]] = try samples.points.map { point in
    guard point.count == 2 else { throw PixelError.invalidGeometry }
    let pixelX = (point[0] * scale).rounded(.toNearestOrEven)
    let pixelY = (point[1] * scale + offsetY).rounded(.toNearestOrEven)
    guard pixelX.isFinite, pixelY.isFinite, pixelX >= 0, pixelY >= 0,
          pixelX < Double(bitmap.pixelsWide), pixelY < Double(bitmap.pixelsHigh) else {
        throw PixelError.invalidGeometry
    }
    let x = Int(pixelX)
    let y = Int(pixelY)
    guard let sample = bitmap.colorAt(x: x, y: y) else {
        throw PixelError.unreadableSample(x, y)
    }
    var components = [sample.redComponent, sample.greenComponent, sample.blueComponent, sample.alphaComponent]
    guard let color = NSColor(colorSpace: bitmap.colorSpace, components: &components, count: 4)
        .usingColorSpace(.sRGB) else {
        throw PixelError.unreadableSample(x, y)
    }
    return [color.redComponent, color.greenComponent, color.blueComponent].map {
        Int((min(1, max(0, $0)) * 255).rounded(.toNearestOrEven))
    }
}
FileHandle.standardOutput.write(try JSONEncoder().encode(colors))
