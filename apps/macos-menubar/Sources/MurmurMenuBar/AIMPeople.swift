import AppKit
import SwiftUI
import MurmurTrayCore

struct AIMPeopleView: View {
    @ObservedObject var model: AIMCompanionModel
    @State private var query = ""
    @State private var policyPerson: AIMCompanionSnapshot.Person?
    @State private var recipient: AIMCompanionSnapshot.Person?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("People & agents")).font(AIMTheme.title)
            Text(L10n.text("Choose a person, then their agent. Messages leave through your server as Alex."))
            TextField(L10n.text("Name, nickname or agent"), text: $query).textFieldStyle(.roundedBorder)
            if let data = model.snapshot {
                ForEach(data.people.filter { person in
                    query.isEmpty || ([person.name, person.nickname ?? ""] + person.agents + Array((person.agent_labels ?? [:]).values)).joined(separator: " ").localizedCaseInsensitiveContains(query)
                }) { person in
                    HStack(alignment: .top, spacing: 12) {
                        AIMPersonAvatar(person: person)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(person.name).font(AIMTheme.heading)
                            if person.approvedPhoto != nil, let note = person.photo_note, !note.isEmpty {
                                Text(L10n.text(note)).font(AIMTheme.meta).foregroundStyle(.secondary)
                            }
                            if let nickname = person.nickname { Text(nickname).foregroundStyle(.secondary).textSelection(.enabled) }
                            ForEach(person.agents, id: \.self) { agent in
                                Text("\(person.agent_labels?[agent] ?? agent) · \(agent)").font(AIMTheme.meta)
                                if let policy = model.snapshot?.peer_policy?.peers[agent] {
                                    Text(L10n.text("Responder") + ": " + (policy.responder == "none" ? L10n.text("Not assigned · manual reply needed") : policy.responder)).font(AIMTheme.meta)
                                    Text(L10n.text("Companion sending") + ": " + (policy.send_allowed ? L10n.text("Allowed") : L10n.text("Disabled")) + " · " + policy.context + " · " + policy.trust).font(AIMTheme.meta)
                                    Text(L10n.text("Policy checked") + " · " + AIMCompanionModel.stamp(data.peer_policy?.observed_at)).font(AIMTheme.meta)
                                    if let reason = policy.wake_reason { Text(L10n.text("Last wake") + ": " + L10n.text(reason)).font(AIMTheme.meta).foregroundStyle(AIMTheme.signal) }
                                }
                                if let owner = data.ownerThread(for: agent), let url = owner.verifiedURL {
                                    Button(L10n.text("Open owner chat") + " · " + owner.title) { NSWorkspace.shared.open(url) }
                                        .help(L10n.text("Open this agent's verified owner chat"))
                                }
                            }
                            Text(person.agents.isEmpty ? L10n.text("No linked agent") : (L10n.text("Last incoming") + " · " + AIMCompanionModel.stamp(person.last_at))).font(AIMTheme.meta)
                            if person.last_at == nil && !(person.writable_agents ?? []).isEmpty {
                                Text(L10n.text("Configured locally · two-way delivery not yet observed")).font(AIMTheme.meta)
                            }
                        }
                        Spacer()
                        VStack {
                            Button(L10n.text("Access & context")) { policyPerson = person }.help(L10n.text("Edit what this person's agents may receive from this app"))
                            if let nick = person.nickname, nick.hasPrefix("@"), let url = URL(string: "https://t.me/" + String(nick.dropFirst())) {
                                Button("Telegram ↗") { NSWorkspace.shared.open(url) }.help(L10n.text("Open a Telegram chat with this person; nothing is sent"))
                            }
                            Button(L10n.text("Connection map")) { openMap(person.id) }.help(L10n.text("Open this person's observed message flows"))
                            Button(L10n.text("History")) { openHistory(person.id) }.help(L10n.text("Open the message history with this person in the dashboard"))
                            if !(person.writable_agents ?? []).isEmpty {
                                Button(L10n.text("Write message")) { recipient = person }.help(L10n.text("Compose a message; it leaves only after you press Send message")).disabled(!model.current)
                            }
                        }
                    }
                    Divider()
                }
                Divider()
                Text(L10n.text("Private contours · status only")).font(AIMTheme.heading)
                if let contours = data.private_contours, !contours.isEmpty {
                    ForEach(contours) { contour in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contour.name).font(AIMTheme.heading)
                            Text(AIMCompanionModel.privateStatus(contour)).font(AIMTheme.meta)
                            Text(L10n.text("Private message bodies and connection details stay outside this view.")).font(AIMTheme.meta)
                        }
                    }
                } else {
                    Text(L10n.text("No private status in this snapshot.")).font(AIMTheme.meta)
                }
                if !model.current { Text(L10n.text("Refresh the server overview before sending.")).foregroundStyle(AIMTheme.signal) }
            } else {
                Text(L10n.text("Connect your server in Settings to load people."))
            }
            Text(L10n.text("An incoming message confirms observed activity. A configured connection alone does not confirm that the other side has imported your reply.")).font(AIMTheme.meta)
        }
        .sheet(item: $recipient) { person in AIMComposeView(person: person) }
        .sheet(item: $policyPerson) { person in AIMPolicyView(person: person) }
    }
    private func openMap(_ actor: String) {
        var parts = URLComponents(string: AIMCompanionModel.board)!
        parts.queryItems = [URLQueryItem(name: "view", value: "mesh"), URLQueryItem(name: "section", value: "map"), URLQueryItem(name: "actor", value: actor)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
    private func openHistory(_ actor: String) {
        var url = URLComponents(string: AIMCompanionModel.board)!
        url.queryItems = [.init(name: "view", value: "mesh"), .init(name: "section", value: "history"), .init(name: "actor", value: actor)]
        if let link = url.url { NSWorkspace.shared.open(link) }
    }
}

/// One explicit submit, one stable UUID. An uncertain result is checked without resending.
struct AIMComposeView: View {
    let person: AIMCompanionSnapshot.Person
    @Environment(\.dismiss) private var dismiss
    @State private var peer: String
    @State private var message = ""
    @State private var includeContext = false
    @State private var selectedPolicy: AIMPeerPolicySnapshot.Policy?
    @State private var requestID = UUID().uuidString.lowercased()
    @State private var attempted = false
    @State private var busy = false
    @State private var receipt: String?
    init(person: AIMCompanionSnapshot.Person) {
        self.person = person
        _peer = State(initialValue: person.writable_agents?.first ?? "")
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
            Text(L10n.text("From Alex · agent-sasha · encrypted Murmur delivery")).font(AIMTheme.meta)
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
                    Button(L10n.text("Send message")) { submit(statusOnly: false) }.help(L10n.text("Send once through the owner-only helper on VM105 with a stable id"))
                        .disabled(busy || selectedPolicy == nil || selectedPolicy?.send_allowed == false || peer.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 8000)
                }
                if busy { ProgressView().controlSize(.small) }
            }
        }.padding(24).frame(width: 620).font(AIMTheme.body)
            .onExitCommand { if !busy { dismiss() } }
            .interactiveDismissDisabled(busy).buttonStyle(AIMQuietButtonStyle())
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
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "ws-povalyaev", policy ? "python3 /home/povalyaev/mesh-comms/mesh_comms_policy.py" : "python3 /home/povalyaev/mesh-comms/send.py"]
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
