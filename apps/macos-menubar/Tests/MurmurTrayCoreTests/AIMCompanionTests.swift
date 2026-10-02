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
    var cursor = AIMCompanionCursor()
    try check(cursor.observe(["old"]).isEmpty, "first observation is quiet")
    try check(cursor.observe(["old", "new"]) == ["new"], "only unseen items notify")
    _ = cursor.observe([])
    try check(cursor.observe(["new"]).isEmpty, "queue reappearance does not notify again")
    var restored = AIMCompanionCursor(seen: cursor.seen)
    try check(restored.observe(["old", "new"]).isEmpty, "restart preserves notification dedupe")
    return 9
}
