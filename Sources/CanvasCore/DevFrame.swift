import CoreGraphics

/// `EASL_DEV_FRAME` ("x y w h", AppKit screen coordinates): where a development instance opens
/// its board window (docs/testing.md). Exactly four finite numbers, a positive width and height;
/// anything else is nil, and the app refuses to open a window on it (`DevInput`).
public enum DevFrame {
    public static func parse(_ text: String) -> CGRect? {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
