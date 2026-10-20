import AppKit
import SwiftUI
import MurmurTrayCore

/// The same server evidence appears in Overview and beside the relevant person.
struct AIMAttentionList: View {
    let data: AIMCompanionSnapshot
    let items: [AIMCompanionSnapshot.Attention.Item]
    var title = "Communication needs attention"
    @MurmurViewState private var expanded = false
    @MurmurViewState private var selectedItem: AIMCompanionSnapshot.Attention.Item?
    @MurmurViewState private var composeItem: AIMCompanionSnapshot.Attention.Item?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title) + " · \(items.count)").font(AIMTheme.heading)
            if items.isEmpty { Text(L10n.text("No communication needs action.")).font(AIMTheme.meta) }
            ForEach(Array(items.prefix(expanded ? 200 : 3))) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(L10n.text(item.kindLabelKey)).font(AIMTheme.meta).foregroundStyle(AIMTheme.signal)
                        Spacer()
                        Text(AIMCompanionModel.stamp(item.date)).font(AIMTheme.meta).foregroundStyle(AIMTheme.muted)
                    }
                    Text(item.title).font(AIMTheme.heading)
                    Text((data.people.first { $0.agents.contains(item.peer) }?.name ?? item.peer)).font(AIMTheme.meta)
                    Text(item.next_action).font(AIMTheme.meta).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let owner = data.ownerThread(for: item.peer), let url = owner.verifiedURL {
                            Button(L10n.text("Continue in Codex")) { NSWorkspace.shared.open(url) }
                        }
                        if let person = data.people.first(where: { $0.agents.contains(item.peer) }) {
                            Button(L10n.text("History")) { selectedItem = item }
                            if (person.writable_agents ?? []).contains(item.peer) {
                                Button(L10n.text("Write message")) { composeItem = item }.disabled(!data.isCurrent())
                            }
                        } else {
                            Button(L10n.text("Connection details")) { AIMCompanionModel.open("?view=mesh&section=sources") }
                        }
                    }
                }.padding(10).background(AIMTheme.muted.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if items.count > 3 {
                Button(L10n.text(expanded ? "Show fewer questions" : "Show more questions")) { expanded.toggle() }
            }
        }
        .sheet(item: $selectedItem) { item in
            AIMMessageSearchView(enabled: true, people: data.people, historyPeer: item.peer)
        }
        .sheet(item: $composeItem) { item in
            if let person = data.people.first(where: { $0.agents.contains(item.peer) }) {
                AIMComposeView(person: person, initialPeer: item.peer)
            }
        }
    }
}
