import AppKit
import Foundation
import SwiftUI
import MurmurTrayCore

/// Executes the bundled, reviewed Python reader in memory on the existing owner SSH host.
/// It installs nothing and never sends, acknowledges, or marks a message read.
enum AIMOwnerRead {
    static func exchange(_ request: [String: String]) throws -> Data {
        guard let payload = try? JSONSerialization.data(withJSONObject: request), payload.count <= 8192,
              let source = readerURL().flatMap({ try? Data(contentsOf: $0) }), source.count <= 32_768
        else { throw CocoaError(.fileReadUnknown) }
        let encoded = source.base64EncodedString()
        let remote = "python3 -B -c 'import base64;exec(compile(base64.b64decode(\"\(encoded)\"),\"<murmur-owner-reader>\",\"exec\"))'"
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "ws-povalyaev", remote]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer { deadline.cancel() }
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > 1_048_576 { process.terminate(); throw CocoaError(.fileReadTooLarge) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    private static func readerURL() -> URL? {
        let packaged = Bundle.main.resourceURL?
            .appendingPathComponent("MurmurMenuBarSpike_MurmurMenuBar.bundle")
        let packagedBundle = packaged.flatMap(Bundle.init(url:))
        let bundle = packagedBundle ?? (Bundle.main.bundleURL.pathExtension == "app" ? nil : Bundle.module)
        return bundle?.url(forResource: "mesh-comms-query", withExtension: "py")
    }
}

struct AIMMessageSearchView: View {
    let enabled: Bool
    let people: [AIMCompanionSnapshot.Person]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var result: AIMMessageSearchResult?
    @State private var busy = false
    @State private var failed = false
    @State private var selected: AIMMessageSearchResult.Match?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("Search messages")).font(AIMTheme.title)
                Spacer()
                Button(L10n.text("Close")) { dismiss() }
            }
            Text(L10n.text("Searches accessible server messages. Private conversations are excluded.")).font(AIMTheme.meta)
            HStack {
                TextField(L10n.text("Words in a message"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button(L10n.text("Search"), action: search)
                    .disabled(!enabled || busy || !(2...160).contains(query.trimmingCharacters(in: .whitespacesAndNewlines).count))
            }
            if busy { ProgressView(L10n.text("Searching server…")) }
            if failed { Text(L10n.text("Message search unavailable. No results were confirmed.")).foregroundStyle(AIMTheme.signal) }
            if let result {
                Text("\(result.total) " + L10n.text("matches") + " · \(result.searched) " + L10n.text("messages checked") + " · " + AIMCompanionModel.stamp(result.source_at)).font(AIMTheme.meta)
                if result.truncated || !result.unavailable.isEmpty {
                    Text(L10n.text("Partial search · some history was unavailable or the result limit was reached.")).foregroundStyle(AIMTheme.signal)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(result.matches, id: \.stableID) { match in
                            Button { selected = match } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(match.excerpt).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                    Text([participant(match.peer_identity), match.direction.map { L10n.text($0) }, AIMCompanionModel.stamp(match.date)].compactMap { $0 }.joined(separator: " · ")).font(AIMTheme.meta)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).help(L10n.text("Read the selected message"))
                            Divider()
                        }
                    }
                }
                if result.matches.isEmpty { Text(L10n.text("No accessible messages matched.")) }
            }
        }.padding(24).frame(width: 660, height: 600).font(AIMTheme.body).buttonStyle(AIMQuietButtonStyle())
            .sheet(item: $selected) { match in AIMMessageDetailView(match: match, participant: participant(match.peer_identity)) }
    }

    private func participant(_ peer: String?) -> String {
        guard let peer else { return "" }
        guard let person = people.first(where: { $0.agents.contains(peer) }) else { return peer }
        return person.name + " · " + (person.agent_labels?[peer] ?? peer)
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !busy, (2...160).contains(term.count) else { return }
        busy = true; failed = false; result = nil
        Task {
            let response = await Task.detached { Result { try AIMMessageSearchResult.decode(AIMOwnerRead.exchange(["action": "search", "query": term])) } }.value
            busy = false
            switch response {
            case .success(let value): result = value
            case .failure: failed = true
            }
        }
    }
}

struct AIMMessageDetailView: View {
    let match: AIMMessageSearchResult.Match
    let participant: String
    @Environment(\.dismiss) private var dismiss
    @State private var message: AIMMessageReadResult?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("Message")).font(AIMTheme.title)
                Spacer()
                Button(L10n.text("Close")) { dismiss() }
            }
            Text([participant, match.direction.map { L10n.text($0) }, AIMCompanionModel.stamp(match.date)].compactMap { $0 }.joined(separator: " · ")).font(AIMTheme.meta)
            if failed { Text(L10n.text("Message unavailable. The search excerpt is the only confirmed text.")).foregroundStyle(AIMTheme.signal) }
            if let message {
                ScrollView { Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if message.truncated { Text(L10n.text("Message shortened by the server.")).font(AIMTheme.meta) }
            } else if !failed { ProgressView(L10n.text("Reading message…")) }
        }.padding(24).frame(width: 620, height: 460).font(AIMTheme.body).buttonStyle(AIMQuietButtonStyle())
            .task {
                let response = await Task.detached {
                    Result { try AIMMessageReadResult.decode(AIMOwnerRead.exchange(["action": "read", "store": match.store, "id": match.id]), expectedID: match.id) }
                }.value
                switch response {
                case .success(let value): message = value
                case .failure: failed = true
                }
            }
    }
}
