import Foundation

/// Product navigation only. Shell pin/theme and transient dialogs keep their own state.
public struct AIMPanelNavigation: Sendable {
    public private(set) var page: String
    private var previousPage: String
    public init(page: String = "Overview") {
        self.page = page
        previousPage = page == "Settings" ? "Overview" : page
    }
    public mutating func select(_ page: String) {
        if page == "Settings" { openSettings(); return }
        self.page = page
        previousPage = page
    }
    public mutating func openSettings() {
        if page != "Settings" { previousPage = page }
        page = "Settings"
    }
    /// True only when the main surface should hide; Settings returns to its prior view.
    public mutating func escape() -> Bool {
        guard page == "Settings" else { return true }
        page = previousPage
        return false
    }
}
