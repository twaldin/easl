import WebKit

// WebKit's public script APIs force a gesture whose teardown can consume a real click's activation.
@MainActor
enum PageScript {
    typealias Completion = @convention(block) @MainActor (Any?, NSError?) -> Void

    private static let selector = NSSelectorFromString("_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:")
    private typealias Method = @convention(c) (AnyObject, Selector, NSString, ObjCBool, NSURL?, NSDictionary?, ObjCBool, WKFrameInfo?, WKContentWorld, Completion?) -> Void

    static let isAvailable: Bool = {
        guard let method = class_getInstanceMethod(WKWebView.self, selector), let types = method_getTypeEncoding(method) else { return false }
        let encoding = String(cString: types).filter { !$0.isNumber }
        return encoding == "v@:@B@@B@@@?" || encoding == "v@:@c@@c@@@?"
    }()

    static func call(_ body: String, _ arguments: [String: Any] = [:], in world: WKContentWorld, on webView: WKWebView, _ done: Completion? = nil) {
        guard isAvailable else {
            done?(nil, NSError(domain: WKError.errorDomain, code: WKError.unknown.rawValue,
                               userInfo: [NSLocalizedDescriptionKey: "this WebKit can't run page scripts without acting as a user gesture"]))
            return
        }
        let method = unsafeBitCast(webView.method(for: selector), to: Method.self)
        method(webView, selector, body as NSString, ObjCBool(true), nil, arguments as NSDictionary, ObjCBool(false), nil, world, done)
    }

    static func value<T: Sendable>(_ body: String, _ arguments: [String: Any] = [:], in world: WKContentWorld, on webView: WKWebView,
                                   _ project: @escaping @MainActor (Any?) -> T) async -> T {
        await withCheckedContinuation { continuation in
            call(body, arguments, in: world, on: webView) { value, error in
                continuation.resume(returning: project(error == nil ? value : nil))
            }
        }
    }
}
