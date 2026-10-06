import SwiftUI
import MurmurTrayCore

enum AIMPolicyTransport {
    nonisolated static func load() throws -> AIMPeerPolicySnapshot {
        try JSONDecoder().decode(AIMPeerPolicySnapshot.self, from: AIMMessageTransport.exchange(Data("{\"action\":\"get\"}".utf8), policy: true))
    }
    nonisolated static func save(_ data: Data) throws -> AIMPeerPolicySnapshot {
        try JSONDecoder().decode(AIMPeerPolicySnapshot.self, from: AIMMessageTransport.exchange(data, policy: true))
    }
}
struct AIMPolicyView: View {
    let person: AIMCompanionSnapshot.Person
    @Environment(\.dismiss) private var dismiss
    @State private var data: AIMPeerPolicySnapshot?
    @State private var peer = ""
    @State private var sendAllowed = true
    @State private var trust = "review_required"
    @State private var context = "message_only"
    @State private var tone = "concise"
    @State private var brief = ""
    @State private var status = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Access & context")).font(AIMTheme.title)
            Text(person.name).font(AIMTheme.heading)
            Picker(L10n.text("Recipient agent"), selection: $peer) {
                ForEach(person.agents.filter { data?.peers[$0] != nil }, id: \.self) { Text($0).tag($0) }
            }.disabled(busy).help(L10n.text("Which agent's rules this sheet edits"))
            if let policy = data?.peers[peer] {
                Text(L10n.text("Responder") + ": " + (policy.responder == "none" ? L10n.text("Not assigned · manual reply needed") : policy.responder)).font(AIMTheme.meta)
                Text(policy.wake_status + " · " + (policy.wake_reason ?? "") + " · " + AIMCompanionModel.stamp(data?.observed_at)).font(AIMTheme.meta)
                Toggle(L10n.text("Allow sending from this app"), isOn: $sendAllowed).help(L10n.text("Off: Write message refuses to send to this agent"))
                Picker(L10n.text("Contact trust"), selection: $trust) {
                    Text(L10n.text("Review each request")).tag("review_required")
                    Text(L10n.text("Known contact · no extra permissions")).tag("trusted_contact")
                }.help(L10n.text("How requests from this contact are reviewed; it grants no file access"))
                Picker(L10n.text("Preferred tone"), selection: $tone) {
                    Text(L10n.text("Concise")).tag("concise"); Text(L10n.text("Friendly")).tag("friendly"); Text(L10n.text("Formal")).tag("formal")
                }.help(L10n.text("The tone the companion prefers; your own text is never rewritten"))
                Picker(L10n.text("Shared context"), selection: $context) {
                    Text(L10n.text("Only the written message")).tag("message_only")
                    Text(L10n.text("Allow this approved brief")).tag("approved_brief")
                }.help(L10n.text("Message only, or a brief you approve here that a send may attach"))
                if context == "approved_brief" { TextEditor(text: $brief).frame(height: 110).border(Color.gray.opacity(0.2)); Text("\(brief.count) / 4000").font(AIMTheme.meta) }
            }
            Text(L10n.text("Rules apply to explicit companion sends. A brief requires a separate attachment choice. Vault permissions, Telegram and existing AI responders are managed separately. Tone is a preference; manual text is unchanged.")).font(AIMTheme.meta).fixedSize(horizontal: false, vertical: true)
            if !status.isEmpty { Text(status) }
            HStack {
                Button(L10n.text("Close")) { dismiss() }.keyboardShortcut(.cancelAction).help(L10n.text("Close without saving the rules")).disabled(busy)
                Button(L10n.text("Reload")) { load() }.help(L10n.text("Read the rules from the server again; unsaved edits are dropped")).disabled(busy)
                Spacer()
                Button(L10n.text("Save rules")) { save() }.help(L10n.text("Save to the server; a newer revision there refuses the write")).disabled(busy || data?.peers[peer] == nil || brief.count > 4000)
            }
        }.padding(24).frame(width: 650).font(AIMTheme.body).buttonStyle(AIMQuietButtonStyle())
            .task { load() }.onChange(of: peer) { _ in populate() }.onExitCommand { if !busy { dismiss() } }
            .interactiveDismissDisabled(busy)
    }
    private func populate() {
        guard let policy = data?.peers[peer] else { return }
        sendAllowed = policy.send_allowed; trust = policy.trust; tone = policy.tone; context = policy.context; brief = policy.brief ?? ""
    }
    private func load() {
        busy = true
        Task {
            let result = await Task.detached { Result { try AIMPolicyTransport.load() } }.value
            busy = false
            switch result {
            case .success(let value): data = value; if peer.isEmpty { peer = person.agents.first { value.peers[$0] != nil } ?? "" }; populate(); status = ""
            case .failure: status = L10n.text("Could not load rules. Nothing changed.")
            }
        }
    }
    private func save() {
        guard let revision = data?.peers[peer]?.revision,
              let payload = try? JSONSerialization.data(withJSONObject: ["action":"set", "peer":peer, "revision":revision, "policy":["send_allowed":sendAllowed,"trust":trust,"tone":tone,"context":context,"brief":context == "approved_brief" ? brief : ""]]) else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try AIMPolicyTransport.save(payload) } }.value
            busy = false
            switch result {
            case .success(let value): data = value; populate(); status = L10n.text("Rules saved. Filesystem access did not change.")
            case .failure: status = L10n.text("Save not confirmed. Reload before trying again.")
            }
        }
    }
}
