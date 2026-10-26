import Foundation

/// A page message may start a turn only after easl itself saw a native click or key in that
/// tile's current document. A DOM event never arms this. One arm authorizes one send, and only
/// for 1.5 seconds. Document and view changes clear it.
public struct HtmlGesturePermit: Equatable, Sendable {
    public static let lifetime: TimeInterval = 1.5

    public struct Identity: Equatable, Sendable {
        public var generation: UInt64
        public var url: String
    }

    private var identity: Identity
    private var armedAt: TimeInterval?
    private var armedGeneration: UInt64?

    public init(url: String) {
        identity = Identity(generation: 0, url: url)
    }

    public var document: Identity { identity }

    /// The tile navigated, reloaded, or its view left the window. The old arm cannot authorize
    /// a send from the replacement document.
    public mutating func reset() {
        identity.generation &+= 1
        armedAt = nil
        armedGeneration = nil
    }

    /// The live page URL changed. Same effect as `reset` when the URL is new.
    public mutating func noteURL(_ url: String) {
        guard identity.url != url else { return }
        identity.url = url
        reset()
    }

    /// A native click or key landed in this document. Replaces an unused arm. Does not authorize
    /// a second send until something consumes this one.
    public mutating func arm(at time: TimeInterval) {
        armedAt = time
        armedGeneration = identity.generation
    }

    /// True once, if this document still has an arm no older than `lifetime`. Anything else is
    /// false and leaves no authorization behind.
    public mutating func consume(at time: TimeInterval) -> Bool {
        guard let armedAt, armedGeneration == identity.generation else {
            self.armedAt = nil
            armedGeneration = nil
            return false
        }
        let age = time - armedAt
        self.armedAt = nil
        armedGeneration = nil
        return age >= 0 && age <= Self.lifetime
    }
}

/// Frame checks for `canvasKit.send`. The page URL, not the page's word, decides.
public enum HtmlSendGate {
    public static func isLivePage(originProtocol: String, originHost: String, isMainFrame: Bool, request: URL?, liveURL: URL?, page: URL) -> Bool {
        guard isMainFrame, originProtocol == HtmlKit.scheme else { return false }
        if !originHost.isEmpty, originHost != HtmlKit.host { return false }
        guard let request, samePage(request, page), let liveURL, samePage(liveURL, page) else { return false }
        return true
    }

    private static func samePage(_ url: URL, _ page: URL) -> Bool {
        url.scheme == HtmlKit.scheme && url.host == HtmlKit.host && url.path == page.path
    }
}

/// Caps for accepted page messages. A refusal keeps nothing and does not count toward the rate.
public enum HtmlSendBudget {
    public static let pageCount = 32
    public static let pageBytes = 256 * 1024
    public static let destinationCount = 128
    public static let destinationBytes = 1024 * 1024
    public static let rateCount = 8
    public static let rateWindow: TimeInterval = 10
    public static let inboxCount = 32
    public static let inboxBytes = 256 * 1024

    public static let pageCountReason = "this page already has \(pageCount) messages waiting"
    public static let pageBytesReason = "this page's waiting messages are at \(pageBytes) bytes"
    public static let destinationCountReason = "the terminal that created this page already has \(destinationCount) messages waiting"
    public static let destinationBytesReason = "the terminal that created this page's waiting messages are at \(destinationBytes) bytes"
    public static let rateReason = "this page already sent \(rateCount) messages in the last \(Int(rateWindow)) seconds"

    /// What the board file stores for one message. Queue bytes use this, not the raw payload.
    public static func retainedBytes(_ message: AgentMessage) -> Int {
        (try? BoardStore.encoder.encode(message).count) ?? Int.max
    }

    /// The inbox `result` object, sorted keys, which is the batch the integration receives.
    public static func responseBytes(_ rendered: [JSONValue]) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let result = JSONValue.object(["messages": .array(rendered)])
        return (try? encoder.encode(result).count) ?? Int.max
    }

    public static func payloadText(_ payload: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func check(page: ObjectID, destination: ObjectID, bytes: Int, queues: [ObjectID: [AgentMessage]], rate: inout HtmlSendRateBook, now: Date) throws {
        if bytes > pageBytes { throw HtmlError.overBudget(pageBytesReason) }
        let fromPage = queues.values.flatMap { $0 }.filter { $0.html == page }
        if fromPage.count + 1 > pageCount { throw HtmlError.overBudget(pageCountReason) }
        if fromPage.reduce(0, { $0 + retainedBytes($1) }) + bytes > pageBytes { throw HtmlError.overBudget(pageBytesReason) }
        let waiting = queues[destination] ?? []
        if waiting.count + 1 > destinationCount { throw HtmlError.overBudget(destinationCountReason) }
        if waiting.reduce(0, { $0 + retainedBytes($1) }) + bytes > destinationBytes { throw HtmlError.overBudget(destinationBytesReason) }
        if !rate.allows(page, at: now) { throw HtmlError.overBudget(rateReason) }
    }

    /// Loads a stored queue without trusting its size. Oversized or over-cap rows are dropped.
    /// A row that cannot fit does not block a later row that can.
    public static func restore(ordinary: [ObjectID: [AgentMessage]], html: [ObjectID: [AgentMessage]], objects: [ObjectID: CanvasObject]) -> (ordinary: [ObjectID: [AgentMessage]], html: [ObjectID: [AgentMessage]]) {
        var user: [ObjectID: [AgentMessage]] = [:]
        var pages: [ObjectID: [AgentMessage]] = [:]
        var seen: [ObjectID: Set<String>] = [:]
        func terminal(_ id: ObjectID) -> Bool { objects[id]?.type == .terminal }
        func take(_ message: AgentMessage, terminal id: ObjectID) {
            guard message.html != nil, !seen[id, default: []].contains(message.id) else { return }
            seen[id, default: []].insert(message.id)
            pages[id, default: []].append(message)
        }
        for (id, waiting) in ordinary where terminal(id) {
            var kept: [AgentMessage] = []
            for message in waiting {
                if message.html != nil { take(message, terminal: id) }
                else { kept.append(message) }
            }
            if !kept.isEmpty { user[id] = kept }
        }
        for (id, waiting) in html where terminal(id) {
            for message in waiting { take(message, terminal: id) }
        }
        return (user, bound(pages))
    }

    static func bound(_ queues: [ObjectID: [AgentMessage]]) -> [ObjectID: [AgentMessage]] {
        var pageCount: [ObjectID: Int] = [:]
        var pageBytes: [ObjectID: Int] = [:]
        var result: [ObjectID: [AgentMessage]] = [:]
        for terminal in queues.keys.sorted() {
            var destCount = 0
            var destBytes = 0
            var kept: [AgentMessage] = []
            for message in queues[terminal] ?? [] {
                guard let page = message.html else { continue }
                let bytes = retainedBytes(message)
                if bytes > Self.pageBytes || bytes > destinationBytes { continue }
                if pageCount[page, default: 0] + 1 > Self.pageCount { continue }
                if pageBytes[page, default: 0] + bytes > Self.pageBytes { continue }
                if destCount + 1 > destinationCount { continue }
                if destBytes + bytes > destinationBytes { continue }
                kept.append(message)
                pageCount[page, default: 0] += 1
                pageBytes[page, default: 0] += bytes
                destCount += 1
                destBytes += bytes
            }
            if !kept.isEmpty { result[terminal] = kept }
        }
        return result
    }
}

/// Accepted send times for the rolling rate window. At most `rateCount` stamps per page, and
/// none for a page that has not sent inside the window. Not saved with the board: a restart is
/// outside the window the cap is for, and a deleted tile drops its stamps.
public struct HtmlSendRateBook: Equatable, Sendable {
    private var stamps: [ObjectID: [Date]] = [:]

    public mutating func allows(_ page: ObjectID, at now: Date) -> Bool {
        prune(page, at: now)
        return (stamps[page]?.count ?? 0) < HtmlSendBudget.rateCount
    }

    public mutating func charge(_ page: ObjectID, at now: Date) {
        prune(page, at: now)
        var kept = stamps[page] ?? []
        kept.append(now)
        if kept.count > HtmlSendBudget.rateCount { kept = Array(kept.suffix(HtmlSendBudget.rateCount)) }
        stamps[page] = kept
        for id in Array(stamps.keys) { prune(id, at: now) }
    }

    public mutating func forget(_ page: ObjectID) {
        stamps[page] = nil
    }

    private mutating func prune(_ page: ObjectID, at now: Date) {
        stamps[page]?.removeAll { now.timeIntervalSince($0) >= HtmlSendBudget.rateWindow }
        if stamps[page]?.isEmpty == true { stamps[page] = nil }
    }
}
