import Foundation

/// Presentation of the owner's explicit sending policy. This is never a liveness check.
public enum AIMConnectionSending: String, Sendable {
    case allowed, blocked, unknown, statusOnly

    public var labelKey: String {
        switch self {
        case .allowed: return "Send allowed"
        case .blocked: return "Send blocked"
        case .unknown: return "Send permission unknown"
        case .statusOnly: return "Status only"
        }
    }
}

extension AIMCompanionSnapshot {
    public struct ConnectionCount: Sendable {
        public let count: Int?
        public let partial: Bool
    }

    /// Sum distinct peer routes for a person. Any missing direction leaves the
    /// known positive sum a lower bound; it cannot manufacture an observed zero.
    public func connectionCount(for person: Person, inbound: Bool) -> ConnectionCount {
        guard !isStatusOnly(person), !person.agents.isEmpty else { return .init(count: nil, partial: false) }
        var total = 0, partial = false
        for agent in Set(person.agents) {
            let flow = person.flows?[agent]
            guard let count = flow?.observedCount(inbound: inbound) else { partial = true; continue }
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else { return .init(count: nil, partial: true) }
            total = sum.partialValue
            partial = partial || flow?.scope != "retained_snapshot"
        }
        return .init(count: partial && total == 0 ? nil : total, partial: partial)
    }

    public func isStatusOnly(_ person: Person, config: AIMEditionConfig = .current) -> Bool {
        let privatePeers = config.privatePeers.union(["shaper-viola", "agent-viola-alex"])
        return person.contact_state == "status_only" || !privatePeers.intersection(person.agents).isEmpty
    }

    /// A route and a fresh, explicit policy are both required. Incoming traffic and trust
    /// labels do not grant sending permission. The server checks the policy again on submit.
    public func connectionSending(for person: Person, agent: String, current: Bool, now: Date = Date(),
                                  config: AIMEditionConfig = .current) -> AIMConnectionSending {
        guard !isStatusOnly(person, config: config) else { return .statusOnly }
        guard current, person.agents.contains(agent),
              let policyDate = Self.date(peer_policy?.observed_at),
              (0..<300).contains(now.timeIntervalSince(policyDate)) else { return .unknown }
        if peer_policy?.peers[agent]?.send_allowed == false { return .blocked }
        guard let writable = person.writable_agents else { return .unknown }
        guard writable.contains(agent) else { return .blocked }
        guard peer_policy?.peers[agent]?.send_allowed == true else { return .unknown }
        return .allowed
    }

    public func connectionSending(for person: Person, current: Bool, now: Date = Date(),
                                  config: AIMEditionConfig = .current) -> AIMConnectionSending {
        guard !isStatusOnly(person, config: config) else { return .statusOnly }
        let states = person.agents.map { connectionSending(for: person, agent: $0, current: current, now: now, config: config) }
        if states.contains(.allowed) { return .allowed }
        if !states.isEmpty && states.allSatisfy({ $0 == .blocked }) { return .blocked }
        return .unknown
    }

    public func firstAllowedConnection(for person: Person, current: Bool) -> String? {
        person.agents.first { connectionSending(for: person, agent: $0, current: current) == .allowed }
    }
}

extension AIMPeerPolicySnapshot.Policy {
    public var sharingLabelKey: String {
        switch context {
        case "message_only": return "Written message only"
        case "approved_brief": return "Approved brief · choose per send"
        default: return "Sharing policy not observed"
        }
    }
}

extension AIMCompanionSnapshot.Person.Flow {
    /// Complete successful sources establish zero. Partial sources establish positive
    /// retained observations only; missing scope or source time never becomes a zero.
    public func observedCount(inbound: Bool) -> Int? {
        guard AIMCompanionSnapshot.date(source_at) != nil,
              ["retained_snapshot", "partial_retained_snapshot"].contains(scope ?? ""),
              let count = inbound ? inbound_count : outbound_count,
              count >= 0, scope == "retained_snapshot" || count > 0 else { return nil }
        return count
    }
}
