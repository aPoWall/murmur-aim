import AppKit
import Carbon
import Combine
import UserNotifications
import SwiftUI
import MurmurTrayCore

@MainActor
private final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                  key.signature == 0x4D75726D, key.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return false }
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey | cmdKey),
                                        EventHotKeyID(signature: 0x4D75726D, id: 1),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        if status != noErr { unregister() }
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

@MainActor
private final class CommandMenuItem: NSMenuItem {
    private let command: () -> Void

    init(_ title: String, enabled: Bool = true, command: @escaping () -> Void) {
        self.command = command
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; isEnabled = enabled
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
    private var shortcut: GlobalShortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The window is the primary entrance; the menu-bar item is a shortcut.
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Preserve the preference written by the previous single MenuBarExtra.
        // This API stores the user's Cmd-drag position; it cannot reveal notch overflow.
        item.autosaveName = "Item-0"
        self.item = item
        item.button?.target = self
        item.button?.action = #selector(statusButtonClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatusItem() }
        }
        let shortcut = GlobalShortcut { [weak self] in self?.toggleWindow() }
        self.shortcut = shortcut
        model.shortcutAvailable = shortcut.register()
        refreshStatusItem()
        // A real window is an independent entrance when macOS hides the status item.
        if !ProcessInfo.processInfo.arguments.contains("--background") { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut?.unregister()
        observation?.cancel()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.showWindow(); completionHandler() }
    }

    private func refreshStatusItem() {
        item?.button?.image = AIMAppMarkView.image(.family, size: 18, mono: true)
        // Keep unread/failure/update visible independently of the family mark.
        item?.button?.title = !model.companion.badge.isEmpty ? model.companion.badge : model.verdict.unread ? " ·" : (model.verdict.indicator == .failed ? " !" : (model.updateAvailable ? " ↑" : ""))
        let entrance = model.shortcutAvailable ? L10n.text("Open Murmur: Control–Option–Command–M")
            : L10n.text("Shortcut unavailable. Open Murmur from Finder.")
        item?.button?.toolTip = model.accessibleStatus + "\n" + entrance
        item?.button?.setAccessibilityLabel(model.accessibleStatus)
    }

    @objc private func statusButtonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let item, let button = item.button else { return }
            let menu = quickMenu()
            menu.delegate = self
            item.menu = menu
            button.performClick(nil)
        } else { toggleWindow() }
    }

    func menuDidClose(_ menu: NSMenu) { item?.menu = nil }

    private func toggleWindow() {
        if window?.isVisible == true { AIMWindowState.shared.close(.menuBarItem) }
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
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = .white
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
        func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            menu.addItem(CommandMenuItem(title, enabled: enabled, command: action))
        }
        add(L10n.text("Open Murmur")) { [weak self] in self?.showWindow() }
        if model.profile != nil || model.isDemo {
            add(model.verdict.reason) { [weak self] in self?.showWindow() }
            menu.addItem(.separator())
        }
        add(L10n.text("Open an existing connection"), enabled: !model.busy && !model.isDemo && model.runtimeError == nil) { [weak self] in
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
        add(L10n.text("Quit")) { NSApp.terminate(nil) }
        return menu
    }
}

@main
struct MurmurMenuBarApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        AIMTheme.registerFonts()
        if AIMPreview.runIfRequested() { return }
        app.setActivationPolicy(.regular)
        let delegate = MurmurAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
