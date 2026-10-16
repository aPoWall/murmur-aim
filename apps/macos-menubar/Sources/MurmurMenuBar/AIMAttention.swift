import SwiftUI
import MurmurTrayCore

/// The same server evidence appears in Overview and beside the relevant person.
struct AIMAttentionList: View {
    let data: AIMCompanionSnapshot
    let items: [AIMCompanionSnapshot.Attention.Item]
    @MurmurViewState private var expanded = false
    @MurmurViewState private var selectedItem: AIMCompanionSnapshot.Attention.Item?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Communication needs attention") + " · \(items.count)").font(AIMTheme.heading)
            if items.isEmpty { Text(L10n.text("No communication needs action.")).font(AIMTheme.meta) }
            ForEach(Array(items.prefix(expanded ? 200 : 3))) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(L10n.text(label(item.kind))).font(AIMTheme.meta).foregroundStyle(AIMTheme.signal)
                        Spacer()
                        Text(AIMCompanionModel.stamp(item.date)).font(AIMTheme.meta).foregroundStyle(AIMTheme.muted)
                    }
                    Text(item.title).font(AIMTheme.heading)
                    Text((data.people.first { $0.agents.contains(item.peer) }?.name ?? item.peer)).font(AIMTheme.meta)
                    Text(item.next_action).font(AIMTheme.meta).fixedSize(horizontal: false, vertical: true)
                    if data.people.contains(where: { $0.agents.contains(item.peer) }) {
                        Button(L10n.text("Read conversation")) { selectedItem = item }
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
    }
    private func label(_ kind: String) -> String {
        switch kind {
        case "owner": return "Your reply or decision"
        case "agent": return "Agent action needed"
        case "delivery": return "Delivery failed"
        default: return "Needs verification"
        }
    }
}
