import AppKit
import Carbon
import Combine
import UserNotifications
import SwiftUI
import MurmurTrayCore

@MainActor
private final class CommandMenuItem: NSMenuItem {
    private let command: () -> Void

    init(_ title: String, enabled: Bool = true, tip: String? = nil, command: @escaping () -> Void) {
        self.command = command
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; isEnabled = enabled; toolTip = tip
    }

    required init(coder: NSCoder) { fatalError("Not used") }
    @objc private func invoke() { command() }
}

@MainActor
private final class MurmurAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    private let model = TrayModel()
    private var item: NSStatusItem?
    private var window: NSWindow?
    private var observation: AnyCancellable?
    /// Rules 49, 50: one family combination, ⌥⌘U by default, recorded in settings.
    private lazy var shortcut = FamilyHotkeyRegistrar(signature: 0x4D75726D) { [weak self] in self?.toggleWindow(reason: .hotkey) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Rule 47: the menu bar item is the entrance, the Dock carries no icon (LSUIElement, accessory policy).
        // Rule 53: the theme is applied before the first window is built.
        AIMThemePolicy.apply(AIMWindowState.shared.theme)
        NSApp.applicationIconImage = AIMTheme.appIcon()
        let appMenu = NSMenu()
        appMenu.addItem(CommandMenuItem(L10n.text("Open Murmur")) { [weak self] in self?.showWindow() })
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        let mainMenu = NSMenu(), appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        // AppKit routes text-editing shortcuts through the responder chain.
        let editMenu = NSMenu(title: L10n.text("Edit"))
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: L10n.text(title), action: action, keyEquivalent: key))
        }
        let editItem = NSMenuItem(title: L10n.text("Edit"), action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        UNUserNotificationCenter.current().delegate = self
        AIMMenuPresence.prepare(screenWidth: Double(NSScreen.screens.map { $0.frame.width }.max() ?? 1440))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Preserve the preference written by the previous single MenuBarExtra.
        // This API stores the user's Cmd-drag position; it cannot reveal notch overflow.
        item.autosaveName = AIMMenuPresence.name
        item.isVisible = true
        self.item = item
        item.button?.target = self
        item.button?.action = #selector(statusButtonClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatusItem() }
        }
        AIMWindowState.shared.onHotkeyChange = { [weak self] combo in self?.registerShortcut(combo) }
        registerShortcut(AIMWindowState.hotkeyStore.current)
        refreshStatusItem()
        // A real window is an independent entrance when macOS hides the status item.
        if !ProcessInfo.processInfo.arguments.contains("--background") { showWindow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let item = self.item else { return }
            AIMMenuPresence.receipt(item, windowVisible: self.window?.isVisible == true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut.unregister()
        observation?.cancel()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.showWindow(); completionHandler() }
    }

    private func refreshStatusItem() {
        item?.button?.image = AIMAppMarkView.image(.murmur, size: 18, mono: true)
        // Stable mark-only width keeps counters from displacing the menu entrance; details remain in the tooltip/panel.
        item?.button?.title = ""
        let combo = AIMWindowState.shared.hotkey
        let entrance = model.shortcutAvailable && combo != nil ? L10n.text("Open Murmur: %@", combo!.display)
            : L10n.text("Shortcut unavailable. Open Murmur from Finder.")
        item?.button?.toolTip = "Murmur AIM · " + AIMTheme.version + "\n" + model.accessibleStatus + "\n" + model.companion.badge + "\n" + entrance
        item?.button?.setAccessibilityLabel("Murmur AIM · " + model.accessibleStatus)
    }

    @objc private func statusButtonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let item, let button = item.button else { return }
            let menu = quickMenu()
            menu.delegate = self
            item.menu = menu
            button.performClick(nil)
        } else { toggleWindow(reason: .menuBarItem) }
    }

    private func registerShortcut(_ combo: FamilyHotkey?) {
        let available = shortcut.register(combo)
        model.shortcutAvailable = available && combo != nil
        AIMWindowState.shared.hotkeyAvailable = available
        refreshStatusItem()
    }

    func menuDidClose(_ menu: NSMenu) { item?.menu = nil }

    private func toggleWindow(reason: AIMSurface.CloseReason) {
        if window?.isVisible == true { AIMWindowState.shared.close(reason) }
        else { showWindow() }
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Murmur AIM"
            window.minSize = NSSize(width: 740, height: 560)
            window.maxSize = NSSize(width: 740, height: 1100)
            window.backgroundColor = AIMAppShellStyle.canvas
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MurmurHomeView(model: model))
            window.center()
            window.setFrameAutosaveName("MurmurMainWindow")
            self.window = window
            AIMWindowState.shared.attach(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        AIMWindowState.shared.surface?.show()
        window?.makeKey()
    }

    private func quickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, tip: String? = nil, action: @escaping () -> Void) {
            menu.addItem(CommandMenuItem(title, enabled: enabled, tip: tip, command: action))
        }
        add(L10n.text("Open Murmur"), tip: L10n.text("Open the window: overview, people, local and help")) { [weak self] in self?.showWindow() }
        if model.profile != nil || model.isDemo {
            add(model.verdict.reason) { [weak self] in self?.showWindow() }
            menu.addItem(.separator())
        }
        add(L10n.text("Open an existing connection"), enabled: !model.busy && !model.isDemo && model.runtimeError == nil, tip: L10n.text("Pick a connection saved on this Mac")) { [weak self] in
            self?.model.chooseProfile()
        }
        add(L10n.text("I have an invitation…"), enabled: model.canUseInvitation) { [weak self] in
            self?.showWindow()
            self?.model.useInvitation()
        }
        if model.profile != nil || model.isDemo {
            add(L10n.text("Refresh status"), enabled: !model.busy && !model.isDemo) { [weak self] in self?.model.refreshStatus() }
            if model.status?.wake.config.enabled != nil {
                add(model.wakeAction.title, enabled: model.canControl) { [weak self] in
                    guard let self else { return }; model.perform(model.wakeAction)
                }
            }
            if model.updateAvailable {
                add(L10n.text("Open release page"), enabled: !model.isDemo) { [weak self] in self?.model.openUpdateRelease() }
            }
            menu.addItem(.separator())
        }
        // New users can always reopen the guided window without knowing a profile path.
        add(L10n.text("Quit"), tip: L10n.text("Quit the app; the background service keeps its own state")) { NSApp.terminate(nil) }
        return menu
    }
}

@main
struct MurmurMenuBarApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        AIMTheme.registerFonts()
        if AIMPreview.runIfRequested() { return }
        // Rule 47 and the LSUIElement key: the family lives in the menu bar; `.regular` overrode the plist and
        // kept a Dock icon up to AIM 4.
        app.setActivationPolicy(.accessory)
        let delegate = MurmurAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
