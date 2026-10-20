import Foundation

@MainActor
final class PromptSubmissionRegistry {
    let epoch = UUID().uuidString
    private let capacity = 4096
    private let lifetime: TimeInterval = 24 * 60 * 60
    private var receipts: [String: Receipt] = [:]

    enum Decision {
        case legacy
        case execute(String)
        case reply(JSONValue)
    }

    private enum State {
        case pending
        case success(JSONValue)
        case refused(ApiRouter.Failure)
        case cancelled
    }

    private struct Receipt {
        let payload: [String: JSONValue]
        let createdAt: Date
        var state: State
    }

    func begin(_ params: JSONValue, now: Date = Date()) throws -> Decision {
        let reconcile: Bool
        if let value = params["reconcile"] {
            guard let flag = value.bool else {
                throw ApiRouter.Failure("invalid_params", "reconcile must be a boolean")
            }
            reconcile = flag
            guard params["submission"] != nil, params["submission"] != .null else {
                throw ApiRouter.Failure("invalid_params", "reconcile requires submission")
            }
        } else {
            reconcile = false
        }
        guard let submission = params["submission"], submission != .null else { return .legacy }
        guard let fields = submission.object,
              fields.count == 3,
              let id = fields["id"]?.string,
              id.wholeMatch(of: /sub_[A-Za-z0-9_-]{4,76}/) != nil,
              let requestEpoch = fields["epoch"]?.string, !requestEpoch.isEmpty, requestEpoch.count <= 80,
              let stamp = fields["createdAt"]?.string,
              stamp.wholeMatch(of: /[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[Tt]([01][0-9]|2[0-3]):[0-5][0-9]:([0-5][0-9]|60)(\.[0-9]+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])/) != nil,
              let createdAt = (try? Date(stamp.uppercased(), strategy: .iso8601))
                ?? (try? Date(stamp.uppercased(), strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
              var payload = params.object else {
            throw ApiRouter.Failure("invalid_params", "submission needs an ASCII sub_ id of 8 to 80 characters, an epoch of 1 to 80 characters and an RFC3339 createdAt")
        }
        payload.removeValue(forKey: "reconcile")
        if let receipt = receipts[id] {
            guard receipt.payload == payload else {
                throw ApiRouter.Failure("invalid_params", "submission id was already used with different prompt params")
            }
            switch receipt.state {
            case .pending: return .reply(Self.delivery("pending"))
            case .success(let result): return .reply(result)
            case .refused(let failure):
                if reconcile {
                    return .reply(.object([
                        "delivery": .string("not-delivered"),
                        "error": .object(["code": .string(failure.code), "message": .string(failure.message)]),
                    ]))
                }
                throw failure
            case .cancelled: return .reply(Self.delivery("not-delivered"))
            }
        }
        guard requestEpoch == epoch,
              now.timeIntervalSince(createdAt) <= lifetime,
              createdAt.timeIntervalSince(now) <= 5 * 60 else {
            return .reply(Self.delivery("unknown"))
        }
        if receipts.count >= capacity {
            receipts = receipts.filter { _, receipt in
                if case .pending = receipt.state { return true }
                return now.timeIntervalSince(receipt.createdAt) <= lifetime
            }
        }
        guard receipts.count < capacity else {
            if reconcile { return .reply(Self.delivery("unknown")) }
            throw ApiRouter.Failure("unavailable", "prompt submission receipts are full; nothing was submitted")
        }
        receipts[id] = Receipt(payload: payload, createdAt: createdAt, state: reconcile ? .cancelled : .pending)
        return reconcile ? .reply(Self.delivery("not-delivered")) : .execute(id)
    }

    func succeeded(_ id: String, result: JSONValue) {
        receipts[id]?.state = .success(result)
    }

    func refused(_ id: String, failure: ApiRouter.Failure) {
        receipts[id]?.state = .refused(failure)
    }

    private static func delivery(_ state: String) -> JSONValue {
        .object(["delivery": .string(state)])
    }
}
