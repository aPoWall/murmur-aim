import AppKit
import Carbon.HIToolbox

// FamilyHotkey · one global combination per product, recorded by pressing it (AIM apps rules 49, 50).
// The same file ships byte for byte in krest (`krest-bar/swift/`) and Murmur AIM
// (`apps/macos-menubar/Sources/MurmurMenuBar/`); the family table below is mirrored in `PrismHotkey.swift`
// of MEM PRISM, `CalendarControl.swift` of Calendar Control and `LayoutPilot.swift` of Language Relay, and
// `signature` is compared with one literal in every self-test, so a table that drifts fails instead of
// refusing different things in five products.

// MARK: - The family table (rules 49, 50)

/// One combination in the currency the products compare: a virtual key code and a Carbon modifier mask.
struct FamilyCombo: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
}

/// Who holds what, across the six products of the family and macOS.
///
/// A static row is the combination a product ships with. A sibling's setting on disk wins where it can be
/// read and the static row is the fallback. Sources: MEM PRISM `dev.alex.mem-prism` key
/// `dev.alex.mem-prism.hotkey`, Calendar Control `~/.config/calendar-control/config.json` field `hotKey`,
/// Language Relay `dev.alex.layout-pilot` key `globalHotkey`, krest `org.aimindset.krest.bar` key
/// `org.aimindset.krest.bar.hotkey`, Murmur AIM `org.aimindset.murmur` key `org.aimindset.murmur.hotkey`.
/// Aside Tweaks keeps its combination in the browser profile, which no native app reads, so it stays static.
enum FamilyHotkeys {
    static let memPrism = "MEM PRISM"
    static let calendarControl = "Calendar Control"
    static let languageRelay = "Language Relay"
    static let asideTweaks = "Aside Tweaks"
    static let krest = "krest"
    static let murmur = "Murmur AIM"

    /// Shipped defaults, rule 49. Aside Tweaks carries both spellings: `⌥⇧A` ships through `chrome.commands`
    /// and `⌥⌘A` is the one the owner sets by hand on `chrome://extensions/shortcuts`.
    static let familyDefaults: [(owner: String, combos: [FamilyCombo])] = [
        (memPrism, [FamilyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(optionKey | cmdKey))]),
        (calendarControl, [FamilyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(optionKey | cmdKey))]),
        (languageRelay, [FamilyCombo(keyCode: UInt32(kVK_ANSI_L), carbonModifiers: UInt32(optionKey | cmdKey))]),
        (asideTweaks, [FamilyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey | shiftKey)),
                       FamilyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey | cmdKey))]),
        (krest, [FamilyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(optionKey | cmdKey))]),
        (murmur, [FamilyCombo(keyCode: UInt32(kVK_ANSI_U), carbonModifiers: UInt32(optionKey | cmdKey))]),
    ]

    /// What macOS holds. A candidate without two modifiers never reaches this list.
    static let systemHeld: [(owner: String, combo: FamilyCombo)] = [
        ("macOS screenshot", FamilyCombo(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(cmdKey | shiftKey))),
        ("macOS screenshot", FamilyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey | shiftKey))),
        ("macOS screenshot", FamilyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(cmdKey | shiftKey))),
        ("macOS log out", FamilyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey | shiftKey))),
        ("macOS lock screen", FamilyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey | controlKey))),
        ("macOS full screen", FamilyCombo(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(cmdKey | controlKey))),
        ("macOS dictionary", FamilyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(cmdKey | controlKey))),
        ("macOS force quit", FamilyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(cmdKey | optionKey))),
        ("macOS finder search", FamilyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | optionKey))),
        ("macOS finder search", FamilyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey))),
    ]

    /// The same literal stands in the self-tests of all five native products.
    static let sharedSignature = "MEM PRISM=46/2304 Calendar Control=8/2304 Language Relay=37/2304 Aside Tweaks=0/2304+0/2560 krest=7/2304 Murmur AIM=32/2304 macOS screenshot=20/768 macOS screenshot=21/768 macOS screenshot=23/768 macOS log out=12/768 macOS lock screen=12/4352 macOS full screen=3/4352 macOS dictionary=2/4352 macOS force quit=53/2304 macOS finder search=49/2304 macOS finder search=49/768"

    /// The contents of both tables in one line.
    static var signature: String {
        let family = familyDefaults.map { row in
            "\(row.owner)=" + row.combos.map { "\($0.keyCode)/\($0.carbonModifiers)" }.sorted().joined(separator: "+")
        }
        let system = systemHeld.map { "\($0.owner)=\($0.combo.keyCode)/\($0.combo.carbonModifiers)" }
        return (family + system).joined(separator: " ")
    }

    /// The six rows as the footer of a settings view prints them, one product per line.
    static var printedRows: [String] {
        familyDefaults.map { row in
            "\(row.owner) " + row.combos.map { FamilyHotkey.display(keyCode: $0.keyCode, carbon: $0.carbonModifiers) }.joined(separator: " / ")
        }
    }

    /// Where a sibling's live combination comes from. Injected so the refusal table can be walked offscreen
    /// with a known answer instead of whatever this Mac happens to hold.
    struct Reader {
        var memPrism: () -> [FamilyCombo]?
        var calendarControl: () -> [FamilyCombo]?
        var languageRelay: () -> [FamilyCombo]?
        var krest: () -> [FamilyCombo]?
        var murmur: () -> [FamilyCombo]?

        /// Nothing readable: every sibling falls back to its shipped default.
        static let absent = Reader(memPrism: { nil }, calendarControl: { nil }, languageRelay: { nil }, krest: { nil }, murmur: { nil })
        static let disk = Reader(memPrism: { FamilyHotkeys.liveStored(suite: "dev.alex.mem-prism", key: "dev.alex.mem-prism.hotkey") },
                                 calendarControl: FamilyHotkeys.liveCalendarControl,
                                 languageRelay: FamilyHotkeys.liveLanguageRelay,
                                 krest: { FamilyHotkeys.liveStored(suite: "org.aimindset.krest.bar", key: "org.aimindset.krest.bar.hotkey") },
                                 murmur: { FamilyHotkeys.liveStored(suite: "org.aimindset.murmur", key: "org.aimindset.murmur.hotkey") })
    }

    /// A product that stores `keyCode:cocoaModifiers:character` under `key` and `key-cleared` when the owner
    /// cleared it. `nil` = nothing stored, the default stands; `[]` = cleared, the product holds nothing.
    static func liveStored(suite: String, key: String) -> [FamilyCombo]? {
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        if defaults.bool(forKey: key + "-cleared") { return [] }
        guard let raw = defaults.string(forKey: key), let stored = FamilyHotkey(storage: raw) else { return nil }
        return [stored.familyCombo]
    }

    static func liveCalendarControl() -> [FamilyCombo]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/calendar-control/config.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if root["hotKeyCleared"] as? Bool == true { return [] }
        guard let stored = root["hotKey"] as? [String: Any],
              let code = stored["keyCode"] as? NSNumber,
              let mods = stored["modifiers"] as? NSNumber else { return nil }
        return [FamilyCombo(keyCode: code.uint32Value, carbonModifiers: mods.uint32Value)]
    }

    /// Relay keeps the id of a curated combination, not the pair, so the ids are mapped here. An id this
    /// table does not know leaves the sibling on its default rather than silently holding nothing.
    static let relayCombos: [String: [FamilyCombo]] = [
        "option-command-l": [FamilyCombo(keyCode: UInt32(kVK_ANSI_L), carbonModifiers: UInt32(optionKey | cmdKey))],
        "control-option-l": [FamilyCombo(keyCode: UInt32(kVK_ANSI_L), carbonModifiers: UInt32(controlKey | optionKey))],
        "option-command-r": [FamilyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(optionKey | cmdKey))],
        "option-command-k": [FamilyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(optionKey | cmdKey))],
        "off": [],
    ]

    static func liveLanguageRelay() -> [FamilyCombo]? {
        guard let defaults = UserDefaults(suiteName: "dev.alex.layout-pilot"),
              let id = defaults.string(forKey: "globalHotkey") else { return nil }
        return relayCombos[id]
    }

    /// Who holds what right now from the point of view of `owner`: the sibling's live setting where it can be
    /// read, its shipped default otherwise, and its own row left out.
    static func holders(excluding owner: String, reader: Reader = .disk) -> [(owner: String, combos: [FamilyCombo])] {
        familyDefaults.compactMap { row in
            guard row.owner != owner else { return nil }
            let live: [FamilyCombo]?
            switch row.owner {
            case memPrism: live = reader.memPrism()
            case calendarControl: live = reader.calendarControl()
            case languageRelay: live = reader.languageRelay()
            case krest: live = reader.krest()
            case murmur: live = reader.murmur()
            default: live = nil
            }
            return (row.owner, live ?? row.combos)
        }
    }

    /// The one line a refused combination prints, or nil when nothing holds it.
    static func refusal(for combo: FamilyCombo, held: [(owner: String, combos: [FamilyCombo])]) -> String? {
        for row in held where row.combos.contains(combo) { return "taken by \(row.owner)" }
        for row in systemHeld where row.combo == combo { return "taken by \(row.owner)" }
        return nil
    }
}

// MARK: - One combination

/// Stored as `keyCode:cocoaModifierRawValue:character`, the form MEM PRISM uses; the character is what the
/// recorder read, so the printed name matches the key that was pressed.
struct FamilyHotkey: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    var character: String

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, character: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
        self.character = character
    }

    init?(storage: String) {
        let parts = storage.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = UInt32(parts[0]), let raw = UInt(parts[1]), !parts[2].isEmpty else { return nil }
        self.init(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: raw), character: String(parts[2]))
    }

    /// What the recorder reads out of one key press. A press that carries no character (a modifier alone,
    /// a dead key) is not a candidate and the recorder keeps waiting.
    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, characters: String?) {
        let character = FamilyHotkey.name(keyCode: keyCode, characters: characters)
        guard !character.isEmpty else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: modifierFlags, character: character)
    }

    var storage: String { "\(keyCode):\(modifiers.rawValue):\(character)" }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    var familyCombo: FamilyCombo { FamilyCombo(keyCode: keyCode, carbonModifiers: carbonModifiers) }

    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "\u{2303}" }
        if modifiers.contains(.option) { text += "\u{2325}" }
        if modifiers.contains(.shift) { text += "\u{21E7}" }
        if modifiers.contains(.command) { text += "\u{2318}" }
        return text + character.uppercased()
    }

    /// The printed form of a table row, where only the key code is known.
    static func display(keyCode: UInt32, carbon: UInt32) -> String {
        var text = ""
        if carbon & UInt32(controlKey) != 0 { text += "\u{2303}" }
        if carbon & UInt32(optionKey) != 0 { text += "\u{2325}" }
        if carbon & UInt32(shiftKey) != 0 { text += "\u{21E7}" }
        if carbon & UInt32(cmdKey) != 0 { text += "\u{2318}" }
        let letters: [Int: String] = [kVK_ANSI_A: "A", kVK_ANSI_C: "C", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_U: "U",
                                      kVK_ANSI_X: "X", kVK_ANSI_K: "K", kVK_ANSI_R: "R", kVK_ANSI_P: "P"]
        return text + (letters[Int(keyCode)] ?? "#\(keyCode)")
    }

    /// The printed name of a pressed key: the character the keyboard produced, or the word for a key that
    /// prints nothing (space, tab, the arrows, the function row).
    static func name(keyCode: UInt16, characters: String?) -> String {
        let named: [Int: String] = [kVK_Space: "space", kVK_Tab: "tab", kVK_Return: "return",
                                    kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}", kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
                                    kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4", kVK_F5: "f5", kVK_F6: "f6",
                                    kVK_F7: "f7", kVK_F8: "f8", kVK_F9: "f9", kVK_F10: "f10", kVK_F11: "f11", kVK_F12: "f12"]
        if let word = named[Int(keyCode)] { return word }
        let raw = (characters ?? "").lowercased()
        guard let first = raw.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F else { return "" }
        return String(first)
    }

    /// Escape cancels a recording, delete clears the combination; both are read before a candidate is built.
    static func isCancel(keyCode: UInt16) -> Bool { Int(keyCode) == kVK_Escape }
    static func isClear(keyCode: UInt16) -> Bool { Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete }

    /// `nil` = free to take; a string is the one line the field prints, naming the owner or the missing
    /// modifier. The predicate of rule 50 as MEM PRISM, Calendar Control and Language Relay carry it: no
    /// modifier, one modifier, a pair the family or macOS holds (named by its owner first), a command pair
    /// without ⌥ or ⌃.
    func conflict(against held: [(owner: String, combos: [FamilyCombo])]) -> String? {
        if modifiers.isEmpty { return "needs a modifier: hold \u{2325} or \u{2303}" }
        if modifiers.rawValue.nonzeroBitCount < 2 { return "needs two modifiers, one alone belongs to the front app" }
        if let taken = FamilyHotkeys.refusal(for: familyCombo, held: held) { return taken }
        if !modifiers.contains(.option) && !modifiers.contains(.control) {
            return "needs \u{2325} or \u{2303}, a plain command pair belongs to the front app"
        }
        return nil
    }
}

// MARK: - Storage and registration

/// The stored combination of one product: `<bundle id>.hotkey` and `<bundle id>.hotkey-cleared`.
struct FamilyHotkeyStore {
    let owner: String
    let fallback: FamilyHotkey
    let key: String
    var defaults: UserDefaults = .standard

    init(owner: String, fallback: FamilyHotkey, bundle: String? = Bundle.main.bundleIdentifier, defaults: UserDefaults = .standard) {
        self.owner = owner
        self.fallback = fallback
        self.key = (bundle ?? "aim.app") + ".hotkey"
        self.defaults = defaults
    }

    /// `nil` when the owner cleared it; the shipped default when nothing is stored.
    var current: FamilyHotkey? {
        if defaults.bool(forKey: key + "-cleared") { return nil }
        return defaults.string(forKey: key).flatMap(FamilyHotkey.init(storage:)) ?? fallback
    }
    func store(_ value: FamilyHotkey?) {
        if let value {
            defaults.set(value.storage, forKey: key)
            defaults.removeObject(forKey: key + "-cleared")
        } else {
            defaults.removeObject(forKey: key)
            defaults.set(true, forKey: key + "-cleared")
        }
    }
}

/// One Carbon hot key, registered for the life of the process; a new combination replaces the old one.
final class FamilyHotkeyRegistrar {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType
    private let action: () -> Void

    init(signature: OSType, action: @escaping () -> Void) {
        self.signature = signature
        self.action = action
    }

    /// `true` when macOS accepted the combination; `false` when another process holds it exclusively.
    @discardableResult
    func register(_ combo: FamilyHotkey?) -> Bool {
        unregisterKey()
        guard let combo else { return true }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
                guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<FamilyHotkeyRegistrar>.fromOpaque(pointer).takeUnretainedValue()
                guard key.signature == registrar.signature, key.id == 1 else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { registrar.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard installed == noErr else { return false }
        }
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: signature, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        if status != noErr { hotKey = nil }
        return status == noErr
    }

    private func unregisterKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    func unregister() {
        unregisterKey()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

// MARK: - The recorder field (rule 50)

/// A press on the field starts recording, the next combination with a modifier is checked and stored, Escape
/// leaves the old value, Delete clears it. The local key monitor lives only for the length of the recording.
final class FamilyHotkeyField: AIMShellButton {
    private let store: FamilyHotkeyStore
    private var monitor: Any?
    private(set) var recording = false
    /// The one line under the field: the refusal reason, the stored combination or the cleared state.
    var onLine: ((String) -> Void)?
    /// Called after a stored change (a new combination or a clear), so the host re-registers.
    var onChange: ((FamilyHotkey?) -> Void)?
    /// Injected for the offscreen walk; the disk reader otherwise.
    var reader: FamilyHotkeys.Reader = .disk

    init(store: FamilyHotkeyStore, width: CGFloat = 160) {
        self.store = store
        super.init(store.current?.display ?? "none", width: width, action: nil)
        identifier = NSUserInterfaceItemIdentifier("hotkey-record")
        toolTip = "press, then hold the new combination: esc keeps the old one, delete clears it"
        target = self
        action = #selector(begin)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("FamilyHotkeyField is built in code") }
    deinit { stop() }

    private func refresh() {
        setCaption(recording ? "press keys\u{2026}" : (store.current?.display ?? "none"))
        isActive = recording
        setAccessibilityLabel(recording ? "recording a global combination" : "global combination \(store.current?.display ?? "none"), press to record")
    }

    @objc private func begin() {
        guard !recording else { return }
        recording = true
        refresh()
        onLine?("recording: hold \u{2325} or \u{2303} with a key \u{00B7} esc keeps \(store.current?.display ?? "none")")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            self.take(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers)
            return nil
        }
    }

    /// One press while recording; public for the offscreen walk, which hands synthetic presses to this path.
    func take(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        if FamilyHotkey.isCancel(keyCode: keyCode) { finish("kept \(store.current?.display ?? "none")"); return }
        if FamilyHotkey.isClear(keyCode: keyCode) {
            store.store(nil); finish("cleared \u{00B7} no global combination"); onChange?(nil); return
        }
        guard let candidate = FamilyHotkey(keyCode: keyCode, modifierFlags: flags, characters: characters) else { return }
        if let refusal = candidate.conflict(against: FamilyHotkeys.holders(excluding: store.owner, reader: reader)) {
            finish("\(candidate.display) refused: \(refusal)")
            return
        }
        store.store(candidate)
        finish("stored \(candidate.display)")
        onChange?(candidate)
    }

    private func finish(_ line: String) {
        stop()
        refresh()
        onLine?(line)
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
