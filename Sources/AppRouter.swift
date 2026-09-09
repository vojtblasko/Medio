import SwiftUI

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var sheet: SheetRoute?
    @Published var sheetPath: [SheetRoute] = []
    @Published var fullScreenCover: SheetRoute?
    @Published private(set) var homeScrollToTopCounter = 0
    @Published private var pushPaths: [AppTab: [SheetRoute]] = [:]
    @Published var moveItemPaths: [String] = []

    init(initialTab: AppTab = .home) {
        selectedTab = initialTab
    }

    var pushPath: [SheetRoute] {
        get { pushPath(for: selectedTab) }
        set { setPushPath(newValue, for: selectedTab) }
    }

    var canGoBackInSheet: Bool {
        !sheetPath.isEmpty
    }

    var currentSheetRoute: SheetRoute? {
        sheetPath.last ?? sheet
    }

    func selectTab(_ tab: AppTab) {
        DiagnosticsCenter.recordInteraction("Selected tab: \(String(describing: tab))")
        selectedTab = tab
    }

    func reselectHomeTab() {
        guard selectedTab == .home else {
            selectedTab = .home
            return
        }

        resetPushStack()
        homeScrollToTopCounter &+= 1
    }

    func present(_ route: SheetRoute) {
        DiagnosticsCenter.recordInteraction("Opened: \(route.id)")
        if sheet == nil {
            sheet = route
            sheetPath.removeAll()
        } else if currentSheetRoute != route {
            sheetPath.append(route)
        }
    }

    func presentMoveItems(_ paths: [String]) {
        moveItemPaths = paths
        present(.moveItems)
    }

    func dismissSheet() {
        DiagnosticsCenter.recordInteraction("Closed current sheet or returned to previous sheet")
        if sheetPath.isEmpty {
            sheet = nil
            moveItemPaths.removeAll()
        } else {
            sheetPath.removeLast()
            if currentSheetRoute != .moveItems {
                moveItemPaths.removeAll()
            }
        }
    }

    func resetSheetStack() {
        sheet = nil
        sheetPath.removeAll()
        moveItemPaths.removeAll()
    }

    func resetPushStack() {
        setPushPath([], for: selectedTab)
    }

    func presentFullScreen(_ route: SheetRoute) {
        fullScreenCover = route
    }

    func dismissFullScreen() {
        fullScreenCover = nil
    }

    func push(_ route: SheetRoute) {
        DiagnosticsCenter.recordInteraction("Navigated to: \(route.id)")
        var path = pushPath(for: selectedTab)
        path.append(route)
        setPushPath(path, for: selectedTab)
    }

    func pop() {
        DiagnosticsCenter.recordInteraction("Used Back in tab navigation")
        var path = pushPath(for: selectedTab)
        guard !path.isEmpty else { return }
        path.removeLast()
        setPushPath(path, for: selectedTab)
    }

    func pushPath(for tab: AppTab) -> [SheetRoute] {
        pushPaths[tab] ?? []
    }

    func setPushPath(_ path: [SheetRoute], for tab: AppTab) {
        var updated = pushPaths
        updated[tab] = path
        pushPaths = updated
    }

    func pushPathBinding(for tab: AppTab) -> Binding<[SheetRoute]> {
        Binding(
            get: { self.pushPath(for: tab) },
            set: { self.setPushPath($0, for: tab) }
        )
    }
}
