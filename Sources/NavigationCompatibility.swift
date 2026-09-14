import SwiftUI
import UIKit

private struct MedioCompactRootChromeKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MedioRootContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 390
}

extension EnvironmentValues {
    var medioRootContentWidth: CGFloat {
        get { self[MedioRootContentWidthKey.self] }
        set { self[MedioRootContentWidthKey.self] = newValue }
    }

    var medioUsesCompactRootChrome: Bool {
        get { self[MedioCompactRootChromeKey.self] }
        set { self[MedioCompactRootChromeKey.self] = newValue }
    }
}

struct CompatibleContentUnavailableView<Description: View>: View {
    private let title: String
    private let systemImage: String
    private let description: Description

    init(_ title: String, systemImage: String) where Description == EmptyView {
        self.title = title
        self.systemImage = systemImage
        self.description = EmptyView()
    }

    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder description: () -> Description
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description()
    }

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                description
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                description
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}

struct CompatibleLabeledContent: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = NSLocalizedString(label, comment: "Property label")
        self.value = value
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            LabeledContent(label, value: value)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

struct CompatibleNavigationStack<Root: View>: View {
    private let root: Root

    init(@ViewBuilder root: () -> Root) {
        self.root = root()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            AvailableNavigationStack(root: root)
        } else {
            NavigationView {
                root
            }
            .navigationViewStyle(.stack)
        }
    }
}

struct CompatibleNavigationPathStack<Route: Hashable, Root: View, Destination: View>: View {
    @Binding private var path: [Route]
    private let root: Root
    private let destination: (Route) -> Destination

    init(
        path: Binding<[Route]>,
        @ViewBuilder root: () -> Root,
        @ViewBuilder destination: @escaping (Route) -> Destination
    ) {
        _path = path
        self.root = root()
        self.destination = destination
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            AvailableNavigationPathStack(
                path: $path,
                root: root,
                destination: destination
            )
        } else {
            NavigationView {
                root
                    .background(
                        LegacyNavigationPathLink(
                            path: $path,
                            index: 0,
                            destination: destination
                        )
                    )
            }
            .navigationViewStyle(.stack)
        }
    }
}

extension View {
    @ViewBuilder
    func compatibleMediumPresentationDetent() -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.medium])
        } else {
            self
        }
    }

    @ViewBuilder
    func compatiblePresentationDragIndicatorVisible() -> some View {
        if #available(iOS 16.0, *) {
            presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatiblePopoverCompactAdaptation() -> some View {
        if #available(iOS 16.4, *) {
            presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleTopScrollContentMargin(_ length: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            contentMargins(.top, length, for: .scrollContent)
        } else {
            self
        }
    }

    @ViewBuilder
    func compactAwareInsetGroupedListStyle() -> some View {
        modifier(CompactAwareInsetGroupedListStyleModifier())
    }

    @ViewBuilder
    func compatibleHiddenDarkNavigationChrome() -> some View {
        modifier(CompatibleHiddenDarkNavigationChromeModifier())
    }

    @ViewBuilder
    func compatibleSelectionFeedback<Value: Equatable>(trigger: Value) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleGlobalTapLogger(
        enabled: Bool,
        _ onTap: @escaping (CGPoint) -> Void
    ) -> some View {
        if #available(iOS 16.0, *) {
            if enabled {
                simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .global)
                        .onEnded { value in
                            onTap(value.location)
                        }
                )
            } else {
                self
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleNavigationDestination<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *) {
            AvailableNavigationDestination(
                root: self,
                isPresented: isPresented,
                destination: destination
            )
        } else {
            background(
                NavigationLink(destination: destination(), isActive: isPresented) {
                    EmptyView()
                }
                .frame(width: 0, height: 0)
                .hidden()
                .accessibilityHidden(true)
            )
        }
    }
}

private struct CompatibleHiddenDarkNavigationChromeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            // This view is presented above the tabs. Changing tab visibility here causes
            // the underlying page controls to animate back during sheet dismissal.
            content
                .toolbarVisibility(.hidden, for: .navigationBar)
        } else if #available(iOS 16.0, *) {
            content
                .toolbar(.hidden, for: .navigationBar)
        } else {
            content
                .navigationBarHidden(true)
                .background(LegacyHiddenNavigationChromeBridge())
        }
    }
}

private struct LegacyHiddenNavigationChromeBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if !context.coordinator.apply(from: uiViewController) {
            DispatchQueue.main.async {
                _ = context.coordinator.apply(from: uiViewController)
            }
        }
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.restore()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private weak var navigationController: UINavigationController?
        private var previousNavigationBarHidden: Bool?

        @discardableResult
        func apply(from viewController: UIViewController) -> Bool {
            guard let navigationController = viewController.navigationController else {
                return false
            }

            if self.navigationController !== navigationController {
                restoreNavigationBar()
                self.navigationController = navigationController
                previousNavigationBarHidden = navigationController.isNavigationBarHidden
            }

            navigationController.setNavigationBarHidden(true, animated: false)
            return true
        }

        func restore() {
            restoreNavigationBar()
        }

        private func restoreNavigationBar() {
            guard let navigationController,
                  let previousNavigationBarHidden else { return }
            if !navigationController.isBeingDismissed {
                navigationController.setNavigationBarHidden(previousNavigationBarHidden, animated: false)
            }
            self.navigationController = nil
            self.previousNavigationBarHidden = nil
        }

    }
}

private struct CompactAwareInsetGroupedListStyleModifier: ViewModifier {
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactChrome

    func body(content: Content) -> some View {
        if usesCompactChrome {
            content.listStyle(.plain)
        } else {
            content.listStyle(.insetGrouped)
        }
    }
}

@available(iOS 16.0, *)
private struct AvailableNavigationStack<Root: View>: View {
    let root: Root

    var body: some View {
        NavigationStack {
            root
        }
    }
}

@available(iOS 16.0, *)
private struct AvailableNavigationPathStack<Route: Hashable, Root: View, Destination: View>: View {
    @Binding var path: [Route]
    let root: Root
    let destination: (Route) -> Destination

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
        }
    }
}

@available(iOS 16.0, *)
private struct AvailableNavigationDestination<Root: View, Destination: View>: View {
    let root: Root
    @Binding var isPresented: Bool
    let destination: () -> Destination

    var body: some View {
        root.navigationDestination(isPresented: $isPresented, destination: destination)
    }
}

private struct LegacyNavigationPathLink<Route: Hashable, Destination: View>: View {
    @Binding var path: [Route]
    let index: Int
    let destination: (Route) -> Destination

    var body: some View {
        if let route {
            NavigationLink(
                destination: legacyDestination(for: route),
                isActive: isActive
            ) {
                EmptyView()
            }
            .frame(width: 0, height: 0)
            .hidden()
            .accessibilityHidden(true)
        }
    }

    private var route: Route? {
        guard path.indices.contains(index) else { return nil }
        return path[index]
    }

    private var isActive: Binding<Bool> {
        Binding(
            get: {
                path.indices.contains(index)
            },
            set: { isActive in
                guard !isActive, path.count > index else { return }
                path.removeLast(path.count - index)
            }
        )
    }

    @ViewBuilder
    private func legacyDestination(for route: Route) -> some View {
        destination(route)
            .background(
                LegacyNavigationPathLink(
                    path: $path,
                    index: index + 1,
                    destination: destination
                )
            )
    }
}
