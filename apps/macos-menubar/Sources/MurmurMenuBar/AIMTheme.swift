import AppKit
import SwiftUI
import CoreText
import MurmurTrayCore

/// N1 product assembly. Shared files are vendored byte-for-byte; transport stays upstream.
@MainActor enum AIMTheme {
    static let ink = Color(nsColor: AIMAppShellStyle.ink)
    static let signal = Color(nsColor: AIMAppShellStyle.signal)
    static let body = Font.custom("IBMPlexMono", size: 12)
    static let heading = Font.custom("IBMPlexMono-SmBld", size: 13)
    static let title = Font.custom("IBMPlexMono-SmBld", size: 18)
    static let meta = Font.custom("IBMPlexMono-Medm", size: 11)
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.12.0"
        return "\(v) · aim 4"
    }
    static func registerFonts() {
        for weight in [400, 500, 600] {
            if let url = Bundle.module.url(forResource: "plex-mono-\(weight)", withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
    static func appIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 196, yRadius: 196).fill()
        AIMAppMarkView.draw(.family, in: NSRect(x: 200, y: 200, width: 624, height: 624), mono: false)
        image.unlockFocus()
        return image
    }
}

struct AIMQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(AIMTheme.body)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(AIMTheme.ink.opacity(enabled ? 1 : 0.4))
            .background(configuration.isPressed ? Color(nsColor: AIMAppShellStyle.selected) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: AIMAppShellStyle.divider), lineWidth: 1))
    }
}

@MainActor final class AIMWindowState: NSObject, NSWindowDelegate {
    static let shared = AIMWindowState()
    var surface: AIMSurface?
    var pinned = false
    func attach(_ window: NSWindow) {
        surface = AIMSurface(host: .window(window), pinned: pinned)
        window.delegate = self
    }
    func close(_ reason: AIMSurface.CloseReason) { surface?.close(reason: reason) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(.commandW); return false }
}

struct AIMHeaderBridge: NSViewRepresentable {
    @Binding var page: String
    let status: String
    func makeNSView(context: Context) -> AIMAppHeader {
        let pin = AIMPinButton(pinned: AIMWindowState.shared.pinned) { value in
            AIMWindowState.shared.pinned = value
            AIMWindowState.shared.surface?.pinned = value
        }
        let header = AIMAppHeader(mark: .family, name: "MURMUR AIM", status: status,
                                 version: AIMTheme.version, width: 708,
                                 onSettings: { page = "Settings" }, pin: pin,
                                 onClose: { AIMWindowState.shared.close(.closeButton) })
        // N1 family character in the header; flat family mark remains in the menu bar.
        let voxel = AIMVoxelView(model: AIMVoxelModels.family)
        voxel.wantsLayer = true
        voxel.layer?.backgroundColor = NSColor.white.cgColor
        voxel.frame = header.markView.bounds
        voxel.autoresizingMask = [.width, .height]
        header.markView.addSubview(voxel)
        header.markView.setAccessibilityLabel("Murmur AIM")
        return header
    }
    func updateNSView(_ view: AIMAppHeader, context: Context) { view.setStatus(status) }
}

struct AIMTabsBridge: NSViewRepresentable {
    @Binding var page: String
    func makeNSView(context: Context) -> AIMTabStrip {
        AIMTabStrip(tabs: [.init(id: "Overview", title: L10n.text("Overview").lowercased()),
                          .init(id: "People", title: L10n.text("People").lowercased()),
                          .init(id: "Home", title: L10n.text("Local").lowercased()),
                          .init(id: "Help", title: L10n.text("Help").lowercased())],
                    selected: page, width: 708, tabWidth: 100, onSelect: { page = $0 })
    }
    func updateNSView(_ view: AIMTabStrip, context: Context) { view.select(page) }
}

struct AIMFooterBridge: NSViewRepresentable {
    let status: String
    func makeNSView(context: Context) -> AIMFooterLine {
        AIMFooterLine(keys: "⌃⌥⌘M toggle", status: status, width: 708,
                      apps: { NSWorkspace.shared.open(URL(string: "https://apps.aimindset.org/murmur/")!) })
    }
    func updateNSView(_ view: AIMFooterLine, context: Context) { view.setStatus(status) }
}

/// Fixture-only offscreen capture; no window, profile, daemon or AI-client changes.
@MainActor enum AIMPreview {
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--aim-icon"), args.indices.contains(index + 1) {
            save(AIMTheme.appIcon(), to: args[index + 1]); return true
        }
        guard let index = args.firstIndex(of: "--aim-render"), args.indices.contains(index + 1) else { return false }
        let model = TrayModel(startRuntime: false)
        if let fixture = args.firstIndex(of: "--aim-fixture"), args.indices.contains(fixture + 1),
           let data = try? Data(contentsOf: URL(fileURLWithPath: args[fixture + 1])) {
            model.companion.snapshot = try? AIMCompanionSnapshot.decode(data)
        }
        let page = args.firstIndex(of: "--aim-page").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "Home"
        let view = NSHostingView(rootView: MurmurHomeView(model: model, initialPage: page))
        view.frame = NSRect(x: 0, y: 0, width: 740, height: 700)
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Offscreen bitmap unavailable") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG unavailable") }
        do { try png.write(to: URL(fileURLWithPath: args[index + 1])) }
        catch { fatalError("Cannot save preview: \(error)") }
        return true
    }
    static func save(_ image: NSImage, to path: String) {
        guard let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else { fatalError("Icon render failed") }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { fatalError("Cannot save icon: \(error)") }
    }
}
