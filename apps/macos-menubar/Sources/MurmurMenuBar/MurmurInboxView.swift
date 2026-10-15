import SwiftUI
import MurmurTrayCore

struct MurmurInboxView: View {
    @ObservedObject var model: TrayModel
    var body: some View {
        if model.status != nil && !model.isDemo {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Incoming messages")).font(.headline)
                if let count = model.status?.inbox.unread { Text(L10n.text("Unread: %@", String(count))) }
                HStack {
                    Button(L10n.text(model.checkingInbox ? "Loading messages…" : "Show latest messages")) { model.readInbox() }
                        .disabled(model.busy || model.checkingInbox)
                    if model.inbox != nil { Button(L10n.text("Hide messages")) { model.inbox = nil } }
                }
                Text(L10n.text("Shows the latest 20 incoming messages. Viewing does not mark them as read or send a reply."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.inboxError { Text(error).foregroundStyle(.red) }
                if let inbox = model.inbox {
                    if inbox.messages.isEmpty { Text(L10n.text("No incoming messages yet")) }
                    ForEach(inbox.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: message.sender).font(.subheadline.weight(.semibold))
                            if let date = timestamp(message.createdAt) { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                            Text(verbatim: message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Button(L10n.text(model.requestingInboxNotifications ? "Waiting for macOS permission…" :
                    (model.inboxNotifications ? "Disable message notifications" : "Enable message notifications"))) { model.toggleInboxNotifications() }
                    .disabled(model.requestingInboxNotifications)
                Text(L10n.text("Notifications show only the unread count when it increases while Murmur is open. Message text stays in the app."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.inboxNotificationError { Text(error).foregroundStyle(.secondary) }
            }
        }
    }
}
