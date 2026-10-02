import Foundation

/// Owner-only projection of existing server observations. Never carries message bodies or keys.
public struct AIMCompanionSnapshot: Decodable, Sendable {
    public struct Person: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let agents: [String]
        public let last_at: String?
        public let nickname: String?
        public let agent_labels: [String: String]?
        public let writable_agents: [String]?
    }
    public struct Question: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String?
        public let peer: String?
        public let status: String?
        public let source_date: String?
        public let reviewed_at: String?
        public let next_action: String?
        public let conversation: String?
        public var needsOwner: Bool { ["awaiting_user", "needs_owner_decision"].contains(status ?? "") }
    }
    public struct Incoming: Decodable, Sendable {
        public let peer: String
        public let conversation: String
        public let ids: [String]
        public let date: String?
    }
    public struct Budget: Decodable, Sendable {
        public let allowed: Bool?
        public let reason: String?
        public let observed_at: String?
        public let fresh: Bool?
    }
    public let peer_policy: AIMPeerPolicySnapshot?
    public let schema: String
    public let privacy: String
    public let snapshot_at: String?
    public let fresh: Bool
    public let people: [Person]
    public let pending_count: Int
    public let decision_count: Int
    public let questions: [Question]
    public let incoming: [Incoming]
    public let budget: Budget
    public let owner_mode: String
    public let transport: String
    public let responder: String
    public let server_version: String
    public let responder_model: String

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 524_288 else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == "aim.murmur.companion/1", value.privacy == "owner-metadata",
              value.pending_count >= 0, value.decision_count >= 0,
              value.decision_count <= value.pending_count else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    public func isCurrent(now: Date = Date()) -> Bool {
        guard fresh, let date = Self.date(snapshot_at) else { return false }
        return (0..<300).contains(now.timeIntervalSince(date))
    }
    public static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
    public var attentionKeys: Set<String> {
        Set(incoming.flatMap { item in item.ids.map { "message:\(item.peer):\($0)" } }
            + questions.filter(\.needsOwner).map { "decision:\($0.id):\($0.source_date ?? "")" })
    }
}

/// First observation establishes a quiet baseline. Old items remain seen after leaving the queue.
public struct AIMCompanionCursor: Sendable {
    public private(set) var seen: Set<String>?
    public init(seen: Set<String>? = nil) { self.seen = seen }
    public mutating func observe(_ keys: Set<String>) -> Set<String> {
        let added = seen.map { keys.subtracting($0) } ?? []
        seen = (seen ?? []).union(keys)
        return added
    }
}

public struct AIMPeerPolicySnapshot: Decodable, Sendable {
    public struct Policy: Decodable, Sendable {
        public let revision: Int
        public let send_allowed: Bool
        public let trust: String
        public let context: String
        public let brief: String?
        public let tone: String
        public let responder: String
        public let wake_status: String
        public let wake_reason: String?
    }
    public let observed_at: String
    public let peers: [String: Policy]
}
