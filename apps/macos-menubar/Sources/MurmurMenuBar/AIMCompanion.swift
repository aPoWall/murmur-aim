import AppKit
import SwiftUI
import UserNotifications
import CryptoKit
import MurmurTrayCore

@MainActor final class AIMCompanionModel: ObservableObject {
    @Published var snapshot: AIMCompanionSnapshot?
    @Published var busy = false
    @Published var failed = false
    @Published var notifications = UserDefaults.standard.bool(forKey: "aimCompanionNotifications")
    @Published var notificationDenied = false
    private var timer: Timer?
    private var cursor = AIMCompanionCursor(seen: UserDefaults.standard.stringArray(forKey: "aimCompanionSeen").map(Set.init))
    static let board = "https://content.aimindset.org/murmur/"
    var enabled: Bool { UserDefaults.standard.bool(forKey: "aimServerEnabled") }
    var current: Bool { !failed && snapshot?.isCurrent() == true }
    var badge: String {
        guard enabled else { return "" }
        guard current, let snapshot else { return " !" }
        let count = snapshot.decision_count + snapshot.incoming.reduce(0) { $0 + $1.ids.count }
        return count > 0 ? " \(count)" : ""
    }
    func start() {
        guard enabled, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func connect() { UserDefaults.standard.set(true, forKey: "aimServerEnabled"); start() }
    func disconnect() {
        UserDefaults.standard.set(false, forKey: "aimServerEnabled")
        timer?.invalidate(); timer = nil; snapshot = nil; failed = false
    }
    func refresh() {
        guard enabled, !busy else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try Self.readServer() } }.value
            busy = false
            guard enabled else { return }
            switch result {
            case .failure: failed = true
            case .success(let data):
                snapshot = data; failed = false
                guard data.isCurrent() else { return }
                let keys = Set(data.attentionKeys.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() })
                let added = cursor.observe(keys)
                // Only hashes are retained. Queue text and people are held in memory.
                let retained = Array(cursor.seen ?? []).sorted().suffix(8192)
                UserDefaults.standard.set(Array(retained), forKey: "aimCompanionSeen")
                if notifications && !added.isEmpty { notify(count: added.count) }
            }
        }
    }
    nonisolated private static func readServer() throws -> AIMCompanionSnapshot {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "ws-povalyaev", "python3 /home/povalyaev/mesh-comms/companion.py"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer { deadline.cancel() }
        var data = Data()
        while true {
            let part = output.fileHandleForReading.availableData
            if part.isEmpty { break }
            data.append(part)
            if data.count > 524_288 { process.terminate(); throw CocoaError(.fileReadTooLarge) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return try AIMCompanionSnapshot.decode(data)
    }
    func toggleNotifications() {
        if notifications {
            notifications = false; UserDefaults.standard.set(false, forKey: "aimCompanionNotifications"); return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                self.notifications = granted; self.notificationDenied = !granted
                UserDefaults.standard.set(granted, forKey: "aimCompanionNotifications")
            }
        }
    }
    private func notify(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Murmur AIM"
        content.body = L10n.text("New messages or decisions to review") + ": \(count)"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }
    static func open(_ path: String = "") {
        guard let url = URL(string: board + path) else { return }
        NSWorkspace.shared.open(url)
    }
    static func owner() { NSWorkspace.shared.open(URL(string: "codex://threads/01a0ed94-6541-7423-a18f-42545746f731")!) }
    static func stamp(_ raw: String?) -> String {
        guard let date = AIMCompanionSnapshot.date(raw) else { return L10n.text("Not observed") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct AIMCompanionView: View {
    @ObservedObject var model: AIMCompanionModel
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Your communication desk")).font(AIMTheme.title)
            Text(L10n.text("People, incoming requests and decisions. Continue the conversation in the owning Codex session.")).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("Dashboard")) { AIMCompanionModel.open() }
                Button(L10n.text("History")) { AIMCompanionModel.open("?view=mesh&section=history") }
                Button(L10n.text("Connections")) { AIMCompanionModel.open("?view=mesh&section=map") }
                Button(L10n.text("Search tools")) { AIMCompanionModel.open("?command=search") }
            }
            if !model.enabled {
                Text(L10n.text("Read the existing VM105 server through your Mac's SSH connection. No new identity or private keys are created."))
                Button(L10n.text("Connect my server overview")) { model.connect() }
            } else {
                HStack {
                    Text("VM105 · agent-sasha").font(AIMTheme.heading)
                    Spacer()
                    Button(L10n.text("Refresh")) { model.refresh() }.disabled(model.busy)
                }
                if model.busy && model.snapshot == nil { ProgressView(L10n.text("Reading server…")) }
                if model.failed {
                    Text(L10n.text("Server overview unavailable. Check Tailscale and SSH ws-povalyaev. Retained observations are stale.")).foregroundStyle(AIMTheme.signal)
                }
                if let data = model.snapshot {
                    Text("Murmur \(data.server_version) · " + L10n.text("Transport") + ": \(data.transport) · " + L10n.text("Codex service") + ": \(data.responder)").font(AIMTheme.meta)
                    Text((model.current ? L10n.text("Snapshot") : L10n.text("Stale snapshot")) + " · " + AIMCompanionModel.stamp(data.snapshot_at)).font(AIMTheme.meta)
                    Text(L10n.text("Alex's decisions") + ": \(data.decision_count) · " + L10n.text("Open topics") + ": \(data.pending_count)").font(AIMTheme.heading)
                    if data.budget.allowed != true || data.budget.fresh != true {
                        Text(L10n.text("Automatic replies need a fresh budget check. Receiving messages continues.")).foregroundStyle(AIMTheme.signal)
                        Text((data.budget.reason ?? "unknown") + " · " + AIMCompanionModel.stamp(data.budget.observed_at)).font(AIMTheme.meta)
                    }
                    Button(L10n.text("Continue with Vasiliev / JARVIS in Codex")) { AIMCompanionModel.owner() }
                    Divider()
                    TextField(L10n.text("Filter people and questions"), text: $query).textFieldStyle(.roundedBorder)
                    Text(L10n.text("Questions to review")).font(AIMTheme.heading)
                    ForEach(data.questions.filter { query.isEmpty || [$0.title, $0.peer, $0.next_action].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query) }) { question in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                Text(question.title ?? question.id).font(AIMTheme.heading)
                                Spacer()
                                if question.needsOwner { Text(L10n.text("Your decision")).foregroundStyle(AIMTheme.signal) }
                            }
                            Text((question.peer ?? "") + " · " + AIMCompanionModel.stamp(question.source_date)).font(AIMTheme.meta)
                            Text(L10n.text("Reviewed") + " · " + AIMCompanionModel.stamp(question.reviewed_at)).font(AIMTheme.meta)
                            if let action = question.next_action { Text(action).fixedSize(horizontal: false, vertical: true) }
                            Button(L10n.text("Read conversation")) {
                                var parts = URLComponents(string: AIMCompanionModel.board)!
                                parts.queryItems = [URLQueryItem(name: "topic", value: question.id)]
                                if let url = parts.url { NSWorkspace.shared.open(url) }
                            }
                        }
                        Divider()
                    }
                    Text(L10n.text("Incoming awaiting review") + ": \(data.incoming.reduce(0) { $0 + $1.ids.count })").font(AIMTheme.heading)
                    ForEach(Array(data.incoming.enumerated()), id: \.offset) { _, row in
                        Text("\(row.peer) · \(row.ids.count) · " + AIMCompanionModel.stamp(row.date)).font(AIMTheme.meta)
                    }
                    Divider()
                    Text(L10n.text("People · last observed message")).font(AIMTheme.heading)
                    ForEach(data.people.filter { query.isEmpty || ($0.name + " " + $0.agents.joined(separator: " ")).localizedCaseInsensitiveContains(query) }) { person in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(person.name).font(AIMTheme.heading)
                            Text(person.agents.joined(separator: ", ") + " · " + AIMCompanionModel.stamp(person.last_at)).font(AIMTheme.meta)
                        }
                    }
                    Text(L10n.text("Message dates show observed activity, not online presence. Topic decisions are reviewed separately.")).font(AIMTheme.meta)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct AIMCompanionSettings: View {
    @ObservedObject var model: AIMCompanionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Server companion")).font(AIMTheme.heading)
            Text("VM105 · ws-povalyaev · agent-sasha").font(AIMTheme.meta)
            Text(L10n.text("Reads existing observations once per minute while the app is running. Server monitoring continues when the app closes."))
            HStack {
                Button(model.enabled ? L10n.text("Disconnect overview") : L10n.text("Connect my server overview")) { model.enabled ? model.disconnect() : model.connect() }
                Button(model.notifications ? L10n.text("Disable notifications") : L10n.text("Enable notifications")) { model.toggleNotifications() }
            }
            if model.notificationDenied { Text(L10n.text("Allow Murmur AIM notifications in macOS System Settings.")).foregroundStyle(AIMTheme.signal) }
            Text(L10n.text("Notifications contain counts only. The first snapshot is silent; new requests appear after it. Delivery does not close a question."))
            Divider()
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct AIMCompanionHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("How these tools work together")).font(AIMTheme.title)
            Text(L10n.text("Mac app: a quiet overview, notifications and shortcuts. Server: encrypted delivery and native WakeMonitor. Dashboard: messages, people, decisions and sources. Codex: the dedicated JARVIS session owns follow-up and decisions."))
            Text(L10n.text("Claude and local Codex profiles remain separate connections. Opening a window does not transfer conversation context or change the server responder."))
            Text(L10n.text("Task archive (formerly Recovery) is a dated dispatcher snapshot. It does not restart tasks or confirm their current status."))
            Text(L10n.text("Dashboard search covers accessible Murmur messages, people, topics, saved tasks and tool names. Other tools' private content is not indexed."))
            Divider()
        }.fixedSize(horizontal: false, vertical: true)
    }
}
