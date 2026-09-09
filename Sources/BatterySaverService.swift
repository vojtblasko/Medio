@preconcurrency import Foundation
import Combine

@MainActor
class BatterySaverService: ObservableObject {
    @Published var isLowPowerModeActive = false
    @Published var manualSaverEnabled = false {
        didSet { updateEffectiveMode() }
    }

    private var powerStateObserver: NSObjectProtocol?

    var effectiveSaver: Bool {
        manualSaverEnabled || isLowPowerModeActive
    }

    init() {
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.powerStateChanged()
            }
        }
        isLowPowerModeActive = ProcessInfo.processInfo.isLowPowerModeEnabled
        updateEffectiveMode()
    }

    deinit {
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
    }

    private func powerStateChanged() {
        isLowPowerModeActive = ProcessInfo.processInfo.isLowPowerModeEnabled
        updateEffectiveMode()
    }

    func updateEffectiveMode() {
        objectWillChange.send()
        ArtworkCache.shared.setLowPowerMode(effectiveSaver)
        // Add any other features that should react to power saving
    }
}
