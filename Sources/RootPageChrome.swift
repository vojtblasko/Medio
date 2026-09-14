import SwiftUI

struct RootPageTitle: View {
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactChrome
    let title: LocalizedStringKey
    var isCollapsed = false

    var body: some View {
        Text(title)
            .font(.system(size: titleFontSize, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .accessibilityAddTraits(.isHeader)
            .animation(.easeInOut(duration: 0.16), value: isCollapsed)
    }

    private var titleFontSize: CGFloat {
        if usesCompactChrome { return 29 }
        return isCollapsed ? 21 : 34
    }
}

struct RootPageTitleToolbar: ToolbarContent {
    let title: LocalizedStringKey
    var isCollapsed = false

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            RootPageTitle(title: title, isCollapsed: isCollapsed)
        }
    }
}

private struct CompatibleRootPageTitleModifier: ViewModifier {
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactChrome
    let title: LocalizedStringKey
    var isCollapsed: Bool

    func body(content: Content) -> some View {
        if usesCompactChrome {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else if #available(iOS 17.0, *) {
            content
                .navigationTitle(title)
                .toolbarTitleDisplayMode(isCollapsed ? .inline : .inlineLarge)
        } else {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    RootPageTitleToolbar(title: title, isCollapsed: isCollapsed)
                }
        }
    }
}

extension View {
    @ViewBuilder
    func compatibleRootPageTitle(_ title: LocalizedStringKey, isCollapsed: Bool = false) -> some View {
        modifier(CompatibleRootPageTitleModifier(title: title, isCollapsed: isCollapsed))
    }

    @ViewBuilder
    func rootChromeCollapseObserver(_ onChange: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y > 18
            } action: { _, isCollapsed in
                onChange(isCollapsed)
            }
        } else {
            self
        }
    }
}

struct CircularTrailingToolbarItem<Content: View>: ToolbarContent {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            content
        }
    }
}
