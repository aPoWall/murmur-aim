import Foundation
import MurmurTrayCore

func runAIMCompanionChecks() throws -> Int {
    var object: [String: Any] = [
        "schema": "aim.murmur.companion/1", "privacy": "owner-metadata",
        "snapshot_at": "2026-09-29T17:00:00Z", "fresh": true,
        "people": [], "questions": [], "incoming": [],
        "pending_count": 2, "decision_count": 1, "budget": [:],
        "owner_mode": "native_server", "transport": "active", "responder": "active",
        "server_version": "2.12.0", "responder_model": "Codex"
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let value = try AIMCompanionSnapshot.decode(data)
    let now = AIMCompanionSnapshot.date("2026-09-29T17:01:00Z")!
    try check(value.isCurrent(now: now), "recent source remains current")
    try check(!value.isCurrent(now: now.addingTimeInterval(300)), "retained snapshots expire without refresh")
    try check(!value.isCurrent(now: now.addingTimeInterval(-120)), "future timestamps fail closed")
    object["people"] = [["id":"person:dan", "name":"Dan", "agents":["agent-danik"], "nickname":"@dan_named", "agent_labels":["agent-danik":"zima blue"], "writable_agents":["agent-danik"]]]
    let people = try AIMCompanionSnapshot.decode(JSONSerialization.data(withJSONObject: object)).people
    try check(people.first?.nickname == "@dan_named" && people.first?.writable_agents == ["agent-danik"], "exact recipient and nickname survive decoding")
    object["privacy"] = "public"
    do { _ = try AIMCompanionSnapshot.decode(JSONSerialization.data(withJSONObject: object)); throw CheckFailure(message: "unsafe projection accepted") }
    catch is CocoaError {} 
    object["privacy"] = "owner-metadata"
    object["questions"] = [
        ["id":"q-alex", "peer":"agent-jarvis", "responsibility":"alex", "status":"awaiting_user"],
        ["id":"q-agent", "peer":"agent-danik", "responsibility":"agent", "status":"awaiting_agent"],
        ["id":"q-peer", "responsibility":"peer", "status":"awaiting_peer"],
        ["id":"q-check", "responsibility":"verify", "status":"unclassified"]]
    object["private_contours"] = [["id":"private-1", "name":"Private line", "privacy":"status-only", "service_active":true]]
    object["owner_threads"] = ["agent-jarvis": ["title":"Owner", "url":"codex://threads/01a0ed94-6541-7423-a18f-42545746f731"]]
    let classified = try AIMCompanionSnapshot.decode(JSONSerialization.data(withJSONObject: object))
    try check(classified.ownerQuestions.map(\.id) == ["q-alex"] && classified.agentQuestions.map(\.id) == ["q-agent"]
              && classified.peerQuestions.map(\.id) == ["q-peer"] && classified.verificationQuestions.map(\.id) == ["q-check"],
              "responsibility is displayed as separate work queues")
    try check(classified.ownerThread(for: "agent-jarvis")?.verifiedURL != nil && classified.ownerThread(for: "agent-danik") == nil,
              "only the exact linked agent receives an owner chat")
    try check(classified.private_contours?.first?.privacy == "status-only", "private contour contains status only")
    object["owner_threads"] = ["agent-jarvis": ["title":"Wrong", "url":"https://example.com"]]
    do { _ = try AIMCompanionSnapshot.decode(JSONSerialization.data(withJSONObject: object)); throw CheckFailure(message: "unsafe owner URL accepted") }
    catch is CocoaError {}
    let match: [String: Any] = ["privacy":"owner-only-search", "matches":[["id":"m-1", "store":"ordinary", "excerpt":"synthetic phrase"]],
                                "total":1, "truncated":false, "searched":20, "unavailable":[], "scope":"ordinary messages", "source_at":"2026-10-05T10:00:00Z"]
    let search = try AIMMessageSearchResult.decode(JSONSerialization.data(withJSONObject: match))
    try check(search.matches.first?.stableID == "ordinary:m-1", "search keeps a stable exact message reference")
    let read = try AIMMessageReadResult.decode(JSONSerialization.data(withJSONObject: ["privacy":"owner-only-on-demand", "id":"m-1", "text":"synthetic text", "truncated":false]), expectedID: "m-1")
    try check(read.text == "synthetic text", "explicit read returns selected message")
    do { _ = try AIMMessageReadResult.decode(JSONSerialization.data(withJSONObject: ["privacy":"owner-only-on-demand", "id":"m-2", "text":"wrong", "truncated":false]), expectedID: "m-1"); throw CheckFailure(message: "mismatched message accepted") }
    catch is CocoaError {}
    var cursor = AIMCompanionCursor()
    try check(cursor.observe(["old"]).isEmpty, "first observation is quiet")
    try check(cursor.observe(["old", "new"]) == ["new"], "only unseen items notify")
    _ = cursor.observe([])
    try check(cursor.observe(["new"]).isEmpty, "queue reappearance does not notify again")
    var restored = AIMCompanionCursor(seen: cursor.seen)
    try check(restored.observe(["old", "new"]).isEmpty, "restart preserves notification dedupe")
    return 16
}
