import AppKit

/// Own status-item recovery only. Panel pinning and other apps' menu items are independent.
@MainActor enum AIMMenuPresence {
    static let name = "Item-0"
    static let positionKey = "NSStatusItem Preferred Position " + name
    /// AppKit coordinates: keep the panel below its own menu item on that display.
    /// A hidden/unmeasurable item keeps the existing window entrance available.
    static func panelFrame(size: NSSize, status: NSRect, visible: NSRect) -> NSRect? {
        guard [size.width, size.height, status.minX, status.minY, status.width, status.height,
               visible.minX, visible.minY, visible.width, visible.height].allSatisfy({ $0.isFinite }),
              size.width > 0, size.height > 0, status.width > 0, status.height > 0,
              visible.width > 0, visible.height > 0 else { return nil }
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x = min(max(status.midX - width / 2, visible.minX), visible.maxX - width)
        let y = min(max(status.minY - 6 - height, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
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
    static func receipt(_ item: NSStatusItem, windowVisible: Bool, lastEvent: String = "launch", panelFrame: NSRect? = nil) {
        let rect = item.button?.window?.frame ?? .zero
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(rect) }
        let data: [String: Any] = [
            "lastEvent": lastEvent, "theme": AIMWindowState.shared.theme.rawValue,
            "panelFrame": panelFrame.map(NSStringFromRect) ?? "unobserved",
            "version": AIMTheme.version, "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundleURL.path, "visible": item.isVisible,
            "frameOnScreen": onScreen, "frame": NSStringFromRect(rect),
            "templateMark": item.button?.image?.isTemplate == true,
            "mode": "mark", "panelPinned": AIMWindowState.shared.pinned,
            "panelVisible": windowVisible, "activationPolicy": NSApp.activationPolicy().rawValue,
            "panelBelowMenu": panelFrame.map { abs(rect.minY - $0.maxY - 6) < 2 } ?? false,
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
