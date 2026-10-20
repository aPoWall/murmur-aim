import AppKit
import SwiftUI
import MurmurTrayCore

/// Relationship view of observed bindings and work; it never infers human presence.
struct AIMConnectionsView: View {
    @ObservedObject var model: AIMCompanionModel
    let openDesk: () -> Void
    let openPeople: () -> Void
    @MurmurViewState private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("People → assistants → your desk")).font(AIMTheme.title)
            Text(L10n.text("Bindings show who owns each assistant. Work counts show who needs to act; they do not prove a person is online.")).font(AIMTheme.meta)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("Read or write to a person"), action: openPeople)
                Button(L10n.text("Open communication desk"), action: openDesk)
                Spacer()
                Button(L10n.text("Dashboard")) { AIMCompanionModel.open("?view=mesh&section=map") }
            }
            if let data = model.snapshot {
                if !model.current { Text(L10n.text("Retained observation · refresh before acting")).foregroundStyle(AIMTheme.signal) }
                Text(AIMCompanionModel.stamp(data.snapshot_at)).font(AIMTheme.meta)
                if data.attention != nil {
                    HStack(alignment: .top, spacing: 20) {
                        summary("Your reply or decision", data.ownerAttentionCount)
                        summary("Assistant action needed", data.attention!.otherUpdates.filter { $0.kind == "agent" }.count)
                        summary("Delivery failed", data.attention!.otherUpdates.filter { $0.kind == "delivery" }.count)
                        summary("Needs verification", data.attention!.items.filter { $0.actionable && $0.kind == "verify" }.count)
                    }
                } else { Text(L10n.text("Work classification not observed")).font(AIMTheme.meta) }
                TextField(L10n.text("Name, nickname or agent"), text: $query).textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    column("Person", width: 142)
                    Text("→").accessibilityHidden(true)
                    column("Assistant", width: 212)
                    Text("→").accessibilityHidden(true)
                    column("Your communication desk", width: 230)
                }.font(AIMTheme.meta).foregroundStyle(AIMTheme.muted)
                Divider()
                let people = data.people.filter { person in
                    query.isEmpty || ([person.name, person.nickname ?? ""] + person.agents + Array((person.agent_labels ?? [:]).values))
                        .joined(separator: " ").localizedCaseInsensitiveContains(query)
                }
                ForEach(people) { person in
                    connection(person, data: data)
                    Divider()
                }
                if people.isEmpty { Text(L10n.text("No contacts match these filters.")) }
            } else {
                Text(L10n.text("Connect your server in Settings to load people."))
            }
        }
    }
    private func column(_ key: String, width: CGFloat) -> some View {
        Text(L10n.text(key)).frame(width: width, alignment: .leading)
    }
    private func summary(_ key: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(count)).font(AIMTheme.title)
            Text(L10n.text(key)).font(AIMTheme.meta).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func connection(_ person: AIMCompanionSnapshot.Person, data: AIMCompanionSnapshot) -> some View {
        let privateLine = person.contact_state == "status_only" || (!person.agents.isEmpty && data.communicationPeer(for: person) == nil)
        let work = privateLine ? [] : (data.attention?.items ?? []).filter { person.agents.contains($0.peer) }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).font(AIMTheme.heading)
                if let nickname = person.nickname { Text(nickname).font(AIMTheme.meta) }
                Text(L10n.text(privateLine ? "Status only" : (person.agents.isEmpty ? "Assistant not observed" : (person.contact_state == "connected" ? "Connected" : "Observed binding")))).font(AIMTheme.meta).foregroundStyle(AIMTheme.muted)
            }.frame(width: 142, alignment: .leading)
            Text("→").foregroundStyle(AIMTheme.muted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                if person.agents.isEmpty { Text(L10n.text("Assistant not observed")) }
                ForEach(person.agents, id: \.self) { agent in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.agent_labels?[agent] ?? agent).font(AIMTheme.heading)
                        if !privateLine {
                            if let policy = data.peer_policy?.peers[agent] {
                                Text(L10n.text("Responder") + ": " + (policy.responder == "none" ? L10n.text("Not assigned · manual reply needed") : policy.responder))
                                Text(L10n.text("Last wake") + ": " + policy.wake_status)
                            } else { Text(L10n.text("Responder not observed")) }
                            if let flow = person.flows?[agent] {
                                Text(L10n.text("Assistant → desk") + ": " + (flow.inbound_count.map { String($0) } ?? L10n.text("Not observed")))
                                Text(L10n.text("Desk → assistant") + ": " + (flow.outbound_count.map { String($0) } ?? L10n.text("Not observed")))
                                Text(L10n.text(flow.scope == "partial_retained_snapshot" ? "Partial retained message counts" :
                                    (flow.scope == "retained_snapshot" ? "Retained message counts" : "Traffic scope not observed"))).foregroundStyle(AIMTheme.muted)
                                if let observed = flow.source_at { Text(L10n.text("Status checked") + ": " + AIMCompanionModel.stamp(observed)).foregroundStyle(AIMTheme.muted) }
                            } else { Text(L10n.text("Traffic counts not observed")) }
                        } else { Text(L10n.text("Status only")) }
                    }.font(AIMTheme.meta).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(width: 212, alignment: .leading)
            Text("→").foregroundStyle(AIMTheme.muted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                if privateLine { Text(L10n.text("Status only")) }
                else if person.agents.isEmpty { Text(L10n.text("Assistant not observed")) }
                else if data.attention == nil { Text(L10n.text("Work classification not observed")) }
                else {
                    workCount("Your reply or decision", work.filter { $0.actionable && $0.kind == "owner" }.count)
                    workCount("Assistant action needed", work.filter { $0.actionable && $0.kind == "agent" }.count)
                    workCount("Delivery failed", work.filter { $0.actionable && $0.kind == "delivery" }.count)
                    workCount("Waiting for people", work.filter { !$0.actionable && $0.kind == "peer" }.count)
                    workCount("Needs verification", work.filter { $0.actionable && $0.kind == "verify" }.count)
                    let retained = work.filter { !$0.actionable && $0.kind != "peer" }.count
                    if retained > 0 { workCount("Retained review candidates", retained) }
                }
            }.font(AIMTheme.meta).frame(width: 230, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }
    private func workCount(_ key: String, _ count: Int) -> some View {
        Text(L10n.text(key) + ": \(count)").foregroundStyle(count > 0 ? AIMTheme.ink : AIMTheme.muted)
    }
}
