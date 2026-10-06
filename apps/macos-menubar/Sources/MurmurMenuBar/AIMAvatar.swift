import AppKit
import ImageIO
import SwiftUI
import MurmurTrayCore

/// Existing roster assets only. No URLSession, arbitrary paths or disk image cache.
enum AIMAvatarLoader {
    static func load(_ person: AIMCompanionSnapshot.Person,
                     exchange: (String) throws -> Data = { try AIMOwnerRead.exchange(["action": "avatar", "person": $0]) }) -> NSImage? {
        guard let response = fetch(person, exchange: exchange) else { return nil }
        return decode(person, response: response)
    }
    static func fetch(_ person: AIMCompanionSnapshot.Person, exchange: (String) throws -> Data = {
        try AIMOwnerRead.exchange(["action": "avatar", "person": $0])
    }) -> Data? {
        guard person.approvedPhoto != nil, let response = try? exchange(person.id), response.count <= 360_000 else { return nil }
        return response
    }
    static func decode(_ person: AIMCompanionSnapshot.Person, response: Data) -> NSImage? {
        guard let photo = person.approvedPhoto, response.count <= 360_000,
              let row = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              row["privacy"] as? String == "owner-approved-avatar", row["person"] as? String == person.id,
              row["photo"] as? String == photo, row["mime"] as? String == "image/jpeg",
              let encoded = row["data"] as? String, let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty, bytes.count <= 262_144,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}

@MainActor enum AIMAvatarCache {
    static var images: [String: NSImage] = [:]
}

struct AIMPersonAvatar: View {
    let person: AIMCompanionSnapshot.Person
    @State private var image: NSImage?
    private let fixtureImage: Bool
    init(person: AIMCompanionSnapshot.Person, initialImage: NSImage? = nil) {
        self.person = person
        self.fixtureImage = initialImage != nil
        _image = State(initialValue: initialImage)
    }
    var body: some View {
        Group {
            if person.approvedPhoto != nil, let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .accessibilityLabel(L10n.text("Photo") + " · " + person.name)
                    .help(person.photo_note ?? person.name)
            } else {
                Text(person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                    .font(AIMTheme.heading).accessibilityHidden(true)
            }
        }
        .frame(width: 40, height: 40).background(Color.gray.opacity(0.08)).clipShape(Circle())
        .task(id: person.approvedPhoto) {
            guard let key = person.approvedPhoto else { image = nil; return }
            if fixtureImage { return }
            image = nil
            if let cached = AIMAvatarCache.images[key] { image = cached; return }
            // Only once per mounted view; no photo polling. Successful bytes stay in memory.
            let response = await Task.detached { AIMAvatarLoader.fetch(person) }.value
            guard !Task.isCancelled else { return }
            let loaded = response.flatMap { AIMAvatarLoader.decode(person, response: $0) }
            if let loaded { AIMAvatarCache.images[key] = loaded }
            image = loaded
        }
    }
}

/// Synthetic image fixture exercises the actual image branch; no SSH/profile reads.
@MainActor enum AIMAvatarChecks {
    static func run() {
        var count = 0
        func need(_ ok: Bool, _ label: String) {
            guard ok else { fatalError("FAIL avatar: " + label) }
            count += 1; print("PASS avatar: " + label)
        }
        func person(_ changes: [String: Any] = [:]) -> AIMCompanionSnapshot.Person {
            var row: [String: Any] = ["id": "person:vasiliev", "name": "Demo teammate", "agents": ["agent-demo"],
                                     "photo": "/mesh-comms-avatar-vasiliev.jpg", "photo_privacy": "owner-approved-avatar"]
            row.merge(changes) { _, new in new }
            return try! JSONDecoder().decode(AIMCompanionSnapshot.Person.self, from: JSONSerialization.data(withJSONObject: row))
        }
        let fixture = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { bounds in
            NSColor(calibratedRed: 0.1, green: 0.5, blue: 0.8, alpha: 1).setFill(); bounds.fill(); return true
        }
        let rep = NSBitmapImageRep(data: fixture.tiffRepresentation!)!
        let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
        var row: [String: Any] = ["privacy":"owner-approved-avatar", "person":"person:vasiliev",
                                 "photo":"/mesh-comms-avatar-vasiliev.jpg", "mime":"image/jpeg", "data":jpg.base64EncodedString()]
        var reads = 0
        let load: (String) throws -> Data = { _ in reads += 1; return try JSONSerialization.data(withJSONObject: row) }
        let approved = person(["photo_note":"Synthetic portrait note"])
        let image = AIMAvatarLoader.load(approved, exchange: load)
        need(image != nil && reads == 1, "approved exact JPEG decodes")
        let view = NSHostingView(rootView: AIMPersonAvatar(person: approved, initialImage: image))
        view.frame = NSRect(x: 0, y: 0, width: 40, height: 40); view.layoutSubtreeIfNeeded()
        let rendered = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rendered)
        let color = rendered.colorAt(x: rendered.pixelsWide / 2, y: rendered.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
        need(color.blueComponent > color.redComponent + 0.2, "approved fixture renders the photograph branch")
        for changes: [String: Any] in [
            ["photo": NSNull()], ["photo":"https://example.com/p.jpg"], ["photo":"/mesh-comms-avatar-dan.jpg"],
            ["photo":"/mesh-comms-avatar-../vasiliev.jpg"], ["photo_privacy":"status-only"],
            ["photo_privacy":NSNull()], ["agents":["agent-viola-alex"]], ["agents":[]],
            ["id":"private:vasiliev"], ["id":"person:unknown"]] {
            reads = 0
            need(AIMAvatarLoader.load(person(changes), exchange: load) == nil && reads == 0,
                 "absent/disallowed/private reference uses initials with zero image reads")
        }
        for changes: [String: Any] in [["person":"person:dan"], ["photo":"/mesh-comms-avatar-dan.jpg"],
                                      ["privacy":"public"], ["mime":"image/png"], ["data":"invalid"]] {
            let original = row; row.merge(changes) { _, new in new }
            need(AIMAvatarLoader.load(approved, exchange: load) == nil, "wrong image envelope fails closed")
            row = original
        }
        need(approved.photo_note == "Synthetic portrait note", "source portrait note survives decoding")
        print("PASS: \(count) avatar checks; synthetic image only")
    }
}
