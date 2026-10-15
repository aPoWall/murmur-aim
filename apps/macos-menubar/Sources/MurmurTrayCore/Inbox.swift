import Foundation

/// Personal inbox returned by the shared CLI. Reading never advances a cursor.
public struct InboxSnapshot: Decodable, Sendable {
    public struct Message: Decodable, Sendable, Identifiable {
        public let conversationId: String, msgId: String, sender: String, text: String, createdAt: String
        public let unread: Bool?
        public var id: String { "\(conversationId.utf8.count):\(conversationId)\(msgId)" }
    }
    public let schema: String, agentId: String
    public let unread: Int?, readCursor: Int?
    public let messages: [Message]

    public static func decode(_ data: Data, expectedAgent: String) throws -> Self {
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schema == "murmur.inbox/1", value.agentId == expectedAgent,
              value.messages.count <= 20, (value.unread ?? 0) >= 0, (value.readCursor ?? 0) >= 0,
              Set(value.messages.map(\.id)).count == value.messages.count,
              value.messages.allSatisfy({ !$0.msgId.isEmpty && !$0.conversationId.isEmpty &&
                  !$0.sender.isEmpty && timestamp($0.createdAt) != nil }) else { throw ProfileError.invalidResponse }
        return value
    }
}

/// Baseline each selected profile and each recovery from an unknown counter.
/// Counts can miss arrivals when another reader consumes messages between polls;
/// notifications deliberately do not claim to be a complete delivery log.
public struct InboxNotificationCounter: Sendable {
    private var previous: Int?
    public init() {}
    public mutating func observe(_ unread: Int?) -> Bool {
        let old = previous
        previous = unread.flatMap { $0 >= 0 ? $0 : nil }
        guard let old, let current = previous else { return false }
        return current > old
    }
}
