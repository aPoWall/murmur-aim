import AppKit

/// Own status-item recovery only. Panel pinning and other apps' menu items are independent.
@MainActor enum AIMMenuPresence {
    static let name = "Item-0"
    static let positionKey = "NSStatusItem Preferred Position " + name
    static func invalidPosition(_ position: Double?, screenWidth: Double) -> Bool {
        guard let position else { return false }
        return !position.isFinite || position < 0 || position > screenWidth
    }
    static func prepare(defaults: UserDefaults = .standard, screenWidth: Double) {
        let position = (defaults.object(forKey: positionKey) as? NSNumber)?.doubleValue
        if invalidPosition(position, screenWidth: screenWidth) {
            defaults.set(160, forKey: positionKey)
        }
        defaults.set(true, forKey: "NSStatusItem Visible " + name)
    }
    static func receipt(_ item: NSStatusItem, windowVisible: Bool) {
        let rect = item.button?.window?.frame ?? .zero
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(rect) }
        let data: [String: Any] = [
            "version": AIMTheme.version, "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundleURL.path, "visible": item.isVisible,
            "frameOnScreen": onScreen, "frame": NSStringFromRect(rect),
            "templateMark": item.button?.image?.isTemplate == true,
            "mode": "mark", "panelPinned": AIMWindowState.shared.pinned,
            "panelVisible": windowVisible, "activationPolicy": NSApp.activationPolicy().rawValue,
            "observedAt": ISO8601DateFormatter().string(from: Date()),
            "limitation": "OS placement only; third-party menu managers and notch occlusion need visual verification"
        ]
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/aim-menu-receipt.json")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? encoded.write(to: path, options: .atomic)
        }
    }
}
