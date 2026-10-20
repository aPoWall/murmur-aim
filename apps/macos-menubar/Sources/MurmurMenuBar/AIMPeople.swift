import AppKit
import SwiftUI
import MurmurTrayCore

/// Compact directory: every current contact has a visible route or an explicit reason.
struct AIMPeopleView: View {
    @ObservedObject var model: AIMCompanionModel
    @MurmurViewState private var query = ""
    @MurmurViewState private var policyPerson: AIMCompanionSnapshot.Person?
    @MurmurViewState private var recipient: AIMCompanionSnapshot.Person?
    @MurmurViewState private var historyPerson: AIMCompanionSnapshot.Person?
    @MurmurViewState private var connectedOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("People & agents")).font(AIMTheme.title)
            Text(L10n.text("Choose a person to read the conversation or send a message through their assistant.")).font(AIMTheme.meta)
            HStack {
                TextField(L10n.text("Name, nickname or agent"), text: $query).textFieldStyle(.roundedBorder)
                Toggle(L10n.text("Connected only"), isOn: $connectedOnly).toggleStyle(.checkbox)
            }
            if let data = model.snapshot {
                let rows = data.people.filter { person in
                    (!connectedOnly || !(person.writable_agents ?? []).isEmpty) &&
                    (query.isEmpty || ([person.name, person.nickname ?? ""] + person.agents + Array((person.agent_labels ?? [:]).values)).joined(separator: " ").localizedCaseInsensitiveContains(query))
                }
                Text("\(rows.count) / \(data.people.count) " + L10n.text("contacts") + " · " + AIMCompanionModel.stamp(data.snapshot_at)).font(AIMTheme.meta)
                ForEach(rows) { person in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            AIMPersonAvatar(person: person, imageReadEnabled: !model.previewConnected)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.name).font(AIMTheme.heading)
                                Text([person.nickname, person.role].compactMap { $0 }.joined(separator: " · ")).font(AIMTheme.meta).foregroundStyle(AIMTheme.muted)
                                Text(person.agents.map { person.agent_labels?[$0] ?? $0 }.joined(separator: " · ")).font(AIMTheme.meta)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(L10n.text("Write message")) { recipient = person }
                                .disabled(!model.current || (person.writable_agents ?? []).isEmpty)
                        }
                        HStack(spacing: 10) {
                            if !person.agents.isEmpty, person.contact_state != "status_only", AIMEditionConfig.current.privatePeers.intersection(person.agents).isEmpty {
                                Button(L10n.text("History")) { historyPerson = person }.disabled(!model.enabled)
                            }
                            Button(L10n.text("Connection map")) { openBoard(person.id, section: "map") }
                            Menu(L10n.text("More")) {
                                Button(L10n.text("History in dashboard")) { openBoard(person.id, section: "history") }
                                if let nick = person.nickname, nick.hasPrefix("@"), let url = URL(string: "https://t.me/" + String(nick.dropFirst())) {
                                    Button("Telegram ↗") { NSWorkspace.shared.open(url) }
                                }
                                ForEach(person.agents, id: \.self) { agent in
                                    if let owner = data.ownerThread(for: agent), let url = owner.verifiedURL {
                                        Button(L10n.text("Open owner chat") + " · " + owner.title) { NSWorkspace.shared.open(url) }
                                    }
                                }
                            }
                        }
                        Text((person.writable_agents ?? []).isEmpty ? L10n.text(person.contact_state == "status_only" ? "Private connection · status only" : "No connected sending route") : L10n.text("Last incoming") + " · " + AIMCompanionModel.stamp(person.last_at)).font(AIMTheme.meta).foregroundStyle(AIMTheme.muted)
                        let attention = data.attentionItems(for: person)
                        if !attention.isEmpty {
                            AIMAttentionList(data: data, items: attention)
                        }
                        if !person.agents.isEmpty {
                            DisclosureGroup(L10n.text("Connection and access details")) {
                                if !(person.writable_agents ?? []).isEmpty {
                                    Button(L10n.text("Connection settings")) { policyPerson = person }
                                }
                                ForEach(person.agents, id: \.self) { agent in
                                    if let policy = data.peer_policy?.peers[agent] {
                                        Text(agent + " · " + L10n.text("Responder") + ": " + (policy.responder == "none" ? L10n.text("Not assigned · manual reply needed") : policy.responder)).font(AIMTheme.meta)
                                        Text(L10n.text("Companion sending") + ": " + L10n.text(policy.send_allowed ? "Allowed" : "Disabled") + " · " + policy.context + " · " + policy.trust).font(AIMTheme.meta)
                                        Text(L10n.text(policy.incomingLabelKey)).font(AIMTheme.meta)
                                        Text(L10n.text("Policy checked") + " · " + AIMCompanionModel.stamp(data.peer_policy?.observed_at)).font(AIMTheme.meta)
                                        if let reason = policy.wake_reason { Text(L10n.text("Last wake") + ": " + L10n.text(reason)).font(AIMTheme.meta) }
                                    }
                                }
                            }
                        }
                    }.padding(.vertical, 8)
                    Divider()
                }
                if rows.isEmpty { Text(L10n.text("No contacts match these filters.")) }
                if !model.current { Text(L10n.text("Refresh the server overview before sending.")).foregroundStyle(AIMTheme.signal) }
            } else {
                Text(L10n.text("Connect your server in Settings to load people."))
            }
        }
        .sheet(item: $recipient) { person in AIMComposeView(person: person) }
        .sheet(item: $policyPerson) { person in AIMPolicyView(person: person) }
        .sheet(item: $historyPerson) { person in
            AIMMessageSearchView(enabled: model.enabled, people: model.snapshot?.people ?? [], historyPeer: person.agents.first)
        }
    }
    private func openBoard(_ actor: String, section: String) {
        guard var parts = URLComponents(string: AIMCompanionModel.board) else { return }
        parts.queryItems = [.init(name: "view", value: "mesh"), .init(name: "section", value: section), .init(name: "actor", value: actor)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
}

/// One explicit submit, one stable UUID. An uncertain result is checked without resending.
struct AIMComposeView: View {
    let person: AIMCompanionSnapshot.Person
    @Environment(\.dismiss) private var dismiss
    @MurmurViewState private var peer: String
    @MurmurViewState private var message = ""
    @MurmurViewState private var includeContext = false
    @MurmurViewState private var selectedPolicy: AIMPeerPolicySnapshot.Policy?
    @MurmurViewState private var requestID = UUID().uuidString.lowercased()
    @MurmurViewState private var attempted = false
    @MurmurViewState private var busy = false
    @MurmurViewState private var receipt: String?
    init(person: AIMCompanionSnapshot.Person, initialPeer: String? = nil) {
        self.person = person
        _peer = State(initialValue: initialPeer.flatMap { person.writable_agents?.contains($0) == true ? $0 : nil } ?? person.writable_agents?.first ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Write message")).font(AIMTheme.title)
            Text(person.name + (person.nickname.map { " · " + $0 } ?? "")).font(AIMTheme.heading)
            Picker(L10n.text("Recipient agent"), selection: $peer) {
                ForEach(person.writable_agents ?? [], id: \.self) { agent in
                    Text("\(person.agent_labels?[agent] ?? agent) · \(agent)").tag(agent)
                }
            }.disabled(attempted).help(L10n.text("Which agent of this person receives the message"))
            Text(L10n.text("From your identity · encrypted Murmur delivery")).font(AIMTheme.meta)
            TextEditor(text: $message).font(AIMTheme.body).frame(height: 180).border(Color.gray.opacity(0.25)).disabled(attempted)
            Text("\(message.count) / 8000").font(AIMTheme.meta)
            if selectedPolicy?.context == "approved_brief" {
                Toggle(L10n.text("Attach the approved brief"), isOn: $includeContext).help(L10n.text("Send the brief approved in Access & context with this message")).disabled(attempted)
                if includeContext { Text(selectedPolicy?.brief ?? "").font(AIMTheme.meta).lineLimit(4) }
            }
            if selectedPolicy?.send_allowed == false { Text(L10n.text("Sending is disabled by your contact policy.")).foregroundStyle(AIMTheme.signal) }
            if let receipt { Text(receipt).textSelection(.enabled) }
            if attempted { Text(L10n.text("Queued or acknowledged delivery does not mean the person has read or answered. Check status before sending another copy.")).font(AIMTheme.meta) }
            HStack {
                Button(L10n.text("Close")) { dismiss() }.keyboardShortcut(.cancelAction).help(L10n.text("Close this sheet; an unsent message is discarded")).disabled(busy)
                Spacer()
                if attempted {
                    Button(L10n.text("Check delivery")) { submit(statusOnly: true) }.help(L10n.text("Ask the server what happened to this attempt; nothing is resent")).disabled(busy)
                } else {
                    Button(L10n.text("Send message")) { submit(statusOnly: false) }.help(L10n.text("Send once through the owner-only helper on your server with a stable id"))
                        .disabled(busy || selectedPolicy == nil || selectedPolicy?.send_allowed == false || peer.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 8000)
                }
                if busy { ProgressView().controlSize(.small) }
            }
        }.padding(24).frame(width: 620).font(AIMTheme.body)
            .onExitCommand { if !busy { dismiss() } }
            .interactiveDismissDisabled(busy).aimQuietButtonStyle()
            .task(id: peer) { includeContext = false; selectedPolicy = nil; if let result = try? await Task.detached(operation: { try AIMPolicyTransport.load() }).value { selectedPolicy = result.peers[peer] } }
    }
    private func submit(statusOnly: Bool) {
        busy = true; attempted = true
        let request: [String: Any] = ["action": statusOnly ? "status" : "send", "request_id": requestID, "peer": peer, "text": message, "include_context": includeContext, "policy_revision": selectedPolicy?.revision ?? -1]
        guard let payload = try? JSONSerialization.data(withJSONObject: request) else { busy = false; return }
        let id = requestID
        Task {
            let result = await Task.detached { Result { try AIMMessageTransport.perform(payload, requestID: id) } }.value
            busy = false
            switch result {
            case .success(let status): receipt = L10n.text("Delivery status") + ": " + status
            case .failure: receipt = L10n.text("Send not confirmed. Check delivery before retrying.")
            }
        }
    }
}

enum AIMMessageTransport {
    nonisolated static func perform(_ payload: Data, requestID: String) throws -> String {
        let data = try exchange(payload, policy: false)
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["request_id"] as? String == requestID, let status = receipt["status"] as? String else { throw CocoaError(.fileReadUnknown) }
        return status
    }
    nonisolated static func exchange(_ payload: Data, policy: Bool) throws -> Data {
        let config = AIMEditionConfig.current
        guard config.canReachServer, let host = config.ownerHost else { throw CocoaError(.fileReadNoPermission) }
        // Relative to the owner's home on that host; `serverRoot` passed validation.
        let helper = config.serverRoot + (policy ? "/mesh_comms_policy.py" : "/send.py")
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", host, "python3 " + helper]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
        defer { deadline.cancel() }
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > 131072 { process.terminate(); throw CocoaError(.fileReadTooLarge) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return data
    }
}
