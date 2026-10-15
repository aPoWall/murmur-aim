import Foundation
import MurmurTrayCore

func runInboxChecks(fixtures: URL) throws -> Int {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("murmur inbox checks \(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let profile = try ProfileBinding(dataDirectory: root.appendingPathComponent("profile ' literal").path)
    let cli = root.appendingPathComponent("fixture cli")
    let script = """
    #!/usr/bin/python3
    import sys,json,datetime
    from pathlib import Path
    root=Path(__file__).parent
    args=sys.argv[1:]
    with (root/'calls.jsonl').open('a') as f: f.write(json.dumps(args)+'\\n')
    key='status' if args[0]=='status' else 'inbox'
    result=json.loads((root/(key+'.json')).read_text())
    if key=='status':
        result['generatedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
        if (root/'change-after').exists() and len((root/'calls.jsonl').read_text().splitlines())==3:
            result['agentId']='different-agent'
    print(json.dumps(result))
    """
    try script.write(to: cli, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    let client = ProfileClient(executable: cli, profile: profile, environment: ["HOME": root.path])
    var status = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("status-green.json"))) as! [String: Any]
    status["agentId"] = "agent-misha"
    let message: [String: Any] = ["conversationId": "conversation", "msgId": "message", "sender": "colleague",
        "text": "<script>not code</script> [not a command](https://example.invalid)", "createdAt": "2026-10-15T15:00:00Z", "unread": true]
    let base: [String: Any] = ["schema": "murmur.inbox/1", "agentId": "agent-misha", "readCursor": 0,
        "unread": 1, "messages": [message]]
    func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func write(_ key: String, _ value: [String: Any]) throws { try data(value).write(to: root.appendingPathComponent(key + ".json")) }
    func calls() throws -> [[String]] {
        try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String]
        }
    }
    var count = 0
    func reject(_ body: () throws -> Void) throws {
        do { try body() } catch is CheckFailure { throw CheckFailure(message: "Inbox assertion failed") }
        catch { count += 1; return }
        throw CheckFailure(message: "Inbox response must be rejected")
    }
    try write("status", status); try write("inbox", base)
    let cursor = root.appendingPathComponent("read-state.json")
    let cursorBytes = Data("unchanged cursor".utf8)
    try cursorBytes.write(to: cursor)
    let snapshot = try client.readInbox(expectedAgent: "agent-misha")
    try check(snapshot.messages.first?.text == message["text"] as? String, "Keep message content as plain data")
    let recorded = try calls()
    try check(recorded.map { $0.first! } == ["status", "inbox", "status"], "Recheck Identity before and after read")
    try check(recorded[1] == ["inbox", "read", "--limit", "20", "--json", "--data-dir", profile.dataDirectory], "Read only with literal selected profile; no mark-read")
    try check(try Data(contentsOf: cursor) == cursorBytes, "Reading preserves cursor bytes")
    count += 4
    for (key, value): (String, Any) in [
        ("schema", "murmur.inbox/2"), ("agentId", "other-agent"), ("unread", -1), ("readCursor", -1),
        ("messages", [message, message]), ("messages", Array(repeating: message, count: 21))
    ] {
        var invalid = base; invalid[key] = value
        try reject { _ = try InboxSnapshot.decode(data(invalid), expectedAgent: "agent-misha") }
    }
    for (key, value) in [("msgId", ""), ("sender", ""), ("createdAt", "not-a-date")] {
        var row = message; row[key] = value
        var invalid = base; invalid["messages"] = [row]
        try reject { _ = try InboxSnapshot.decode(data(invalid), expectedAgent: "agent-misha") }
    }
    var unknown = base; unknown["unread"] = NSNull(); unknown["readCursor"] = NSNull()
    try check(try InboxSnapshot.decode(data(unknown), expectedAgent: "agent-misha").unread == nil, "Unknown is not zero")
    count += 1
    try Data().write(to: root.appendingPathComponent("calls.jsonl"))
    try Data().write(to: root.appendingPathComponent("change-after"))
    try reject { _ = try client.readInbox(expectedAgent: "agent-misha") }
    try check(try calls().count == 3, "Changed Identity after read hides content without a retry")
    try Data().write(to: root.appendingPathComponent("calls.jsonl"))
    status["agentId"] = "different-agent"; try write("status", status)
    try reject { _ = try client.readInbox(expectedAgent: "agent-misha") }
    try check(try calls().count == 1, "Wrong Identity blocks reading messages")
    count += 2
    var counter = InboxNotificationCounter()
    for (unread, notify): (Int?, Bool) in [(3, false), (3, false), (4, true), (1, false), (2, true),
                                         (nil, false), (100, false), (101, true), (-1, false), (5, false)] {
        try check(counter.observe(unread) == notify, "Notification baseline/increase/unknown: \(String(describing: unread))")
        count += 1
    }
    print("PASS inbox: read-only selected profile, identity changes, response validation, notification baseline")
    return count
}
