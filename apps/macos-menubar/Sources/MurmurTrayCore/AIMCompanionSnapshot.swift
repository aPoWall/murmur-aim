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
        public let photo: String?
        public let photo_note: String?
        public let photo_privacy: String?
        public var approvedPhoto: String? {
            let allowed = Set(["alex", "ira", "dan", "vlada", "katya", "anca", "mykhailo", "olya", "vasiliev", "sergey", "khabarov", "kirill_oleinichenko"])
            let privatePeers = Set(["shaper-viola", "agent-viola-alex", "alex-viola"])
            guard id.hasPrefix("person:"), allowed.contains(String(id.dropFirst(7))),
                  photo_privacy == "owner-approved-avatar", !agents.isEmpty,
                  agents.allSatisfy({ !privatePeers.contains($0) }),
                  let photo, photo == "/mesh-comms-avatar-" + id.dropFirst(7) + ".jpg"
            else { return nil }
            return photo
        }
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
        public let responsibility: String?
        public let source_id: String?
        public var needsOwner: Bool {
            if let responsibility { return responsibility == "alex" }
            return ["awaiting_user", "needs_owner_decision"].contains(status ?? "")
        }
        public var waitingForAgent: Bool { responsibility == "agent" }
        public var waitingForPeer: Bool { responsibility == "peer" }
        public var needsVerification: Bool { responsibility == "verify" }
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
    public struct PrivateContour: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let privacy: String
        public let service_active: Bool?
        public let last_at: String?
        public let updated_at: String?
        public let inbound_count: Int?
        public let outbound_count: Int?
        public let failed_count: Int?
        public let waiting_count: Int?
    }
    public struct OwnerThread: Decodable, Sendable {
        public let title: String
        public let url: String
        public var verifiedURL: URL? {
            guard let components = URLComponents(string: url), components.scheme == "codex",
                  components.host == "threads", !components.path.isEmpty,
                  components.query == nil, components.fragment == nil else { return nil }
            return components.url
        }
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
    public let private_contours: [PrivateContour]?
    public let owner_threads: [String: OwnerThread]?
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
              value.decision_count <= value.pending_count,
              (value.private_contours ?? []).allSatisfy({ $0.privacy == "status-only" }),
              (value.owner_threads ?? [:]).values.allSatisfy({ $0.verifiedURL != nil })
        else { throw CocoaError(.fileReadCorruptFile) }
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
    public var ownerQuestions: [Question] { questions.filter(\.needsOwner) }
    public var agentQuestions: [Question] { questions.filter(\.waitingForAgent) }
    public var peerQuestions: [Question] { questions.filter(\.waitingForPeer) }
    public var verificationQuestions: [Question] { questions.filter(\.needsVerification) }
    public func ownerThread(for peer: String?) -> OwnerThread? {
        guard let peer else { return nil }
        return owner_threads?[peer]
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

/// Read-only owner search. Bodies are fetched only after an explicit selection.
public struct AIMMessageSearchResult: Decodable, Sendable {
    public struct Match: Decodable, Identifiable, Sendable {
        public let id: String
        public let store: String
        public let date: String?
        public let peer_identity: String?
        public let local_identity: String?
        public let direction: String?
        public let conversation_id: String?
        public let excerpt: String
        public var stableID: String { store + ":" + id }
    }
    public let privacy: String
    public let matches: [Match]
    public let total: Int
    public let truncated: Bool
    public let searched: Int
    public let unavailable: [String]
    public let source_at: String?
    public let scope: String

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.privacy == "owner-only-search", value.total >= 0, value.searched >= 0,
              value.matches.count <= 100, value.matches.allSatisfy({ !$0.store.isEmpty && !$0.id.isEmpty })
        else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}

public struct AIMMessageReadResult: Decodable, Sendable {
    public let privacy: String
    public let id: String
    public let text: String
    public let truncated: Bool
    public static func decode(_ data: Data, expectedID: String) throws -> Self {
        guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.privacy == "owner-only-on-demand", value.id == expectedID else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}
