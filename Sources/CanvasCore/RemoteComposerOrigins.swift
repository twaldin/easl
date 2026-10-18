import Foundation

struct RemoteComposerOrigins {
    private var held: [ObjectID: [MentionID: Mention]] = [:]

    mutating func hold(_ mentions: [Mention], for terminal: ObjectID) -> [Mention] {
        mentions.map { original in
            var wire = original
            wire.id = IDs.make("men")
            held[terminal, default: [:]][wire.id] = original
            return wire
        }
    }

    mutating func release(_ ids: [MentionID], for terminal: ObjectID) {
        for id in ids { held[terminal]?.removeValue(forKey: id) }
        if held[terminal]?.isEmpty == true { held.removeValue(forKey: terminal) }
    }

    mutating func consume(_ raw: JSONValue, event: String?, viewer: String) -> (terminal: ObjectID, mentions: [Mention])? {
        guard raw["viewer"]?.string == viewer,
              let receipt = raw["receipt"]?.string, !receipt.isEmpty,
              let terminal = raw["terminal"]?.string,
              let kind = event ?? raw["event"]?.string,
              kind == "composer.returned" || kind == "composer.submitted" else { return nil }
        let ids = raw["ids"]?.array?.compactMap(\.string) ?? []
        var mentions: [Mention] = []
        for id in ids {
            if let original = held[terminal]?.removeValue(forKey: id), kind == "composer.returned" {
                mentions.append(original)
            }
        }
        if held[terminal]?.isEmpty == true { held.removeValue(forKey: terminal) }
        return mentions.isEmpty ? nil : (terminal, mentions)
    }
}
