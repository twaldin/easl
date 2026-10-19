import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A parsed allowNetwork authority. A missing port permits any valid HTTP(S) port.
/// Subdomain rules include the named host itself. IPv6 hosts use canonical brackets.
public struct HostNetworkRule: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int?
    public let subdomains: Bool
}

public enum HostNetworkPolicy {
    public static func rules(allow: [String]) -> [HostNetworkRule] {
        allow.compactMap { entry in
            if let normalized = HtmlKit.allowedHost(entry) {
                let subdomains = normalized.hasPrefix("*.")
                var host = subdomains ? String(normalized.dropFirst(2)) : normalized
                var port: Int?
                if let colon = host.lastIndex(of: ":") {
                    port = Int(host[host.index(after: colon)...])
                    host = String(host[..<colon])
                }
                return HostNetworkRule(host: host, port: port, subdomains: subdomains)
            }
            guard entry.first == "[", let closing = entry.firstIndex(of: "]"),
                  let host = canonicalIPv6(String(entry[...closing])) else { return nil }
            let suffix = entry[entry.index(after: closing)...]
            let port: Int?
            if suffix.isEmpty {
                port = nil
            } else {
                guard suffix.first == ":", let value = networkPort(suffix.dropFirst()) else { return nil }
                port = value
            }
            return HostNetworkRule(host: host, port: port, subdomains: false)
        }
    }

    public static func permits(_ url: URL, rules: [HostNetworkRule]) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let origin = HostNetworkOrigin(components) else { return false }
        return rules.contains { origin.matches($0) }
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        guard let a = URLComponents(url: first, resolvingAgainstBaseURL: true).flatMap(HostNetworkOrigin.init),
              let b = URLComponents(url: second, resolvingAgainstBaseURL: true).flatMap(HostNetworkOrigin.init) else { return false }
        return a == b
    }
}

/// One page's capability map. Each random hostname grants one exact HTTP(S) origin.
/// Replace the whole map when its owning web view loads a page or changes hosts.
public struct HostURLMap {
    private let rules: [HostNetworkRule]
    private var grants: [HostNetworkOrigin: String] = [:]
    private var origins: [String: HostNetworkOrigin] = [:]

    public init(allow: [String]) {
        rules = HostNetworkPolicy.rules(allow: allow)
    }

    public mutating func proxyURL(for original: URL) -> URL? {
        guard var components = URLComponents(url: original, resolvingAgainstBaseURL: true),
              let origin = HostNetworkOrigin(components),
              rules.contains(where: { origin.matches($0) }) else { return nil }
        let grant: String
        if let existing = grants[origin] {
            grant = existing
        } else {
            var candidate: String
            repeat {
                candidate = "p-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            } while origins[candidate] != nil
            grants[origin] = candidate
            origins[candidate] = origin
            grant = candidate
        }
        components.scheme = HtmlKit.scheme
        components.host = grant
        components.port = nil
        return components.url
    }

    public func originalURL(for proxy: URL) -> URL? {
        guard var components = URLComponents(url: proxy, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == HtmlKit.scheme,
              let authority = networkAuthority(components), authority.port == nil,
              let origin = origins[authority.host] else { return nil }
        components.scheme = origin.scheme
        components.host = origin.host
        components.port = origin.port == origin.defaultPort ? nil : origin.port
        return components.url
    }

    public func contains(host: String) -> Bool {
        origins[host.lowercased()] != nil
    }

    public mutating func rewriteHTML(in text: String) -> String {
        Self.rewrite(text, matching: Self.htmlNodes) { node, match in
            if node.hasPrefix("<!--") { return node }
            let raw = match.range(at: 1).location != NSNotFound
            guard raw, let opening = node.range(of: Self.tagPattern, options: .regularExpression) else {
                return rewriteAttributes(node)
            }
            let tag = String(node[opening])
            let prefix = rewriteAttributes(tag)
            guard tag.lowercased().hasPrefix("<style") else {
                return prefix + node[opening.upperBound...]
            }
            let end = node.range(of: Self.styleEnd, options: [.regularExpression, .caseInsensitive])?.lowerBound ?? node.endIndex
            return prefix + rewriteCSS(in: String(node[opening.upperBound..<end])) + node[end...]
        }
    }

    public mutating func rewriteCSS(in text: String) -> String {
        Self.rewrite(text, matching: Self.cssURLs) { part, match in
            Self.replaceOperand(in: part, match: match, indices: 1...5) { rewriteURL($0) }
        }
    }

    private mutating func rewriteAttributes(_ text: String) -> String {
        Self.rewrite(text, matching: Self.resourceAttributes) { attribute, match in
            let name = (text as NSString).substring(with: match.range(at: 1)).lowercased()
            return Self.replaceOperand(in: attribute, match: match, indices: 2...4) { value in
                if name == "style" { return rewriteCSS(in: value) }
                if name == "srcset" { return rewriteSrcset(value) }
                return rewriteURL(value)
            }
        }
    }

    private static func rewrite(_ text: String, matching pattern: NSRegularExpression,
                                transform: (String, NSTextCheckingResult) -> String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result.append(contentsOf: text[cursor..<range.lowerBound])
            result += transform(String(text[range]), match)
            cursor = range.upperBound
        }
        result.append(contentsOf: text[cursor...])
        return result
    }

    private static func replaceOperand(in text: String, match: NSTextCheckingResult, indices: ClosedRange<Int>,
                                transform: (String) -> String) -> String {
        for index in indices {
            let value = match.range(at: index)
            guard value.location != NSNotFound,
                  let range = Range(NSRange(location: value.location - match.range.location, length: value.length), in: text) else { continue }
            return text[..<range.lowerBound] + transform(String(text[range])) + text[range.upperBound...]
        }
        return text
    }

    private mutating func rewriteURL(_ text: String) -> String {
        guard let original = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let proxy = proxyURL(for: original) else { return text }
        return proxy.absoluteString
    }

    private mutating func rewriteSrcset(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var cursor = text.startIndex
        var copied = cursor
        while cursor < text.endIndex {
            while cursor < text.endIndex, Self.srcsetSpace(text[cursor]) || text[cursor] == "," {
                text.formIndex(after: &cursor)
            }
            let start = cursor
            while cursor < text.endIndex, !Self.srcsetSpace(text[cursor]) {
                text.formIndex(after: &cursor)
            }
            var end = cursor
            while end > start, text[text.index(before: end)] == "," { text.formIndex(before: &end) }
            if start < end {
                result += text[copied..<start]
                result += rewriteURL(String(text[start..<end]))
                copied = end
            }
            if end < cursor { continue }
            while cursor < text.endIndex, text[cursor] != "," { text.formIndex(after: &cursor) }
        }
        result += text[copied...]
        return result
    }

    private static func srcsetSpace(_ character: Character) -> Bool {
        switch character {
        case " ", "\t", "\r", "\n", "\u{000C}": true
        default: false
        }
    }

    private static let tagPattern = #"<(?:"[^"]*"|'[^']*'|[^'">])*>"#
    private static let styleEnd = #"</style(?=[\s/>])(?:"[^"]*"|'[^']*'|[^'">])*>"#
    private static let htmlNodes = try! NSRegularExpression(
        pattern: #"<(script|style|textarea|title|xmp|iframe|noembed|noframes|noscript)\b(?:"[^"]*"|'[^']*'|[^'">])*>(?:[\s\S]*?</\1(?=[\s/>])(?:"[^"]*"|'[^']*'|[^'">])*>|[\s\S]*$)|<!--[\s\S]*?(?:-->|$)|<(?:"[^"]*"|'[^']*'|[^'">])*>"#,
        options: .caseInsensitive
    )
    private static let resourceAttributes = try! NSRegularExpression(
        pattern: #"(?<![\w:-])(src|href|poster|srcset|style)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
        options: .caseInsensitive
    )
    private static let cssURLs = try! NSRegularExpression(
        pattern: #"/\*[\s\S]*?\*/|\burl\(\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|([^)\s]*))\s*\)|@import\s+(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)')|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#,
        options: .caseInsensitive
    )
}

private struct HostNetworkOrigin: Hashable {
    let scheme: String
    let host: String
    let port: Int

    var defaultPort: Int { scheme == "https" ? 443 : 80 }

    init?(_ components: URLComponents) {
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let authority = networkAuthority(components) else { return nil }
        let host: String
        if authority.host.hasPrefix("[") {
            guard let canonical = canonicalIPv6(authority.host) else { return nil }
            host = canonical
        } else {
            guard !authority.host.hasPrefix("*"), HtmlKit.allowedHost(authority.host) == authority.host else { return nil }
            host = authority.host
        }
        self.scheme = scheme
        self.host = host
        port = authority.port ?? (scheme == "https" ? 443 : 80)
    }

    func matches(_ rule: HostNetworkRule) -> Bool {
        (rule.port == nil || rule.port == port)
            && (host == rule.host || (rule.subdomains && host.hasSuffix(rule.host)
                && host.dropLast(rule.host.count).last == "."))
    }
}

private func networkPort(_ digits: Substring) -> Int? {
    guard (1...5).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
          let port = Int(digits), (1...65535).contains(port) else { return nil }
    return port
}

private func networkAuthority(_ components: URLComponents) -> (host: String, port: Int?)? {
    guard components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
          let host = components.percentEncodedHost?.lowercased(), !host.isEmpty,
          let string = components.string, let start = string.range(of: "://")?.upperBound else { return nil }
    let authority = string[start...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    guard authority.prefix(host.count).lowercased() == host else { return nil }
    let suffix = authority.dropFirst(host.count)
    if suffix.isEmpty {
        guard components.port == nil else { return nil }
        return (host, nil)
    }
    guard suffix.first == ":", let port = networkPort(suffix.dropFirst()), components.port == port else { return nil }
    return (host, port)
}

private func canonicalIPv6(_ host: String) -> String? {
    guard host.first == "[", host.last == "]" else { return nil }
    let literal = String(host.dropFirst().dropLast())
    guard literal.utf8.allSatisfy({ byte in
        switch byte {
        case 48...57, 65...70, 97...102, 46, 58: true
        default: false
        }
    }) else { return nil }
    var address = in6_addr()
    guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
    // WHATWG URL.hostname uses hexadecimal words even for IPv4-mapped addresses.
    return withUnsafeBytes(of: address) { bytes in
        func word(_ index: Int) -> UInt16 {
            UInt16(bytes[index * 2]) << 8 | UInt16(bytes[index * 2 + 1])
        }
        var bestStart = 0
        var bestLength = 0
        var index = 0
        while index < 8 {
            let start = index
            while index < 8 && word(index) == 0 { index += 1 }
            if index - start > bestLength {
                bestStart = start
                bestLength = index - start
            }
            index += 1
        }
        var result = "["
        index = 0
        while index < 8 {
            if bestLength > 1 && index == bestStart {
                result += "::"
                index += bestLength
            } else {
                if index > 0 && !(bestLength > 1 && index == bestStart + bestLength) { result += ":" }
                result += String(word(index), radix: 16)
                index += 1
            }
        }
        return result + "]"
    }
}
