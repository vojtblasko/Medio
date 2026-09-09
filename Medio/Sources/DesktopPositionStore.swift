import CoreGraphics
import Foundation

enum MedioDesktopPositionStore {
    private struct StoredPoint: Codable {
        let x: Double
        let y: Double
        let canvasWidth: Double?
        let canvasHeight: Double?

        init(_ point: CGPoint, canvasSize: CGSize?) {
            x = point.x
            y = point.y
            canvasWidth = canvasSize.map { Double($0.width) }
            canvasHeight = canvasSize.map { Double($0.height) }
        }

        func point(in canvasSize: CGSize?) -> CGPoint {
            guard let canvasSize, let canvasWidth, canvasWidth > 0 else {
                return CGPoint(x: x, y: y)
            }
            let scaledX = x * Double(canvasSize.width) / canvasWidth
            let scaledY: Double
            if let canvasHeight, canvasHeight > 0, canvasSize.height > 0 {
                scaledY = y * Double(canvasSize.height) / canvasHeight
            } else {
                scaledY = y
            }
            return CGPoint(x: scaledX, y: scaledY)
        }
    }

    private static let defaultsKey = "medio.desktop.positions.v1"

    static func positions(
        in containerPath: String,
        canvasSize: CGSize? = nil,
        defaults: UserDefaults = .standard
    ) -> [String: CGPoint] {
        let all = load(defaults: defaults)
        let stored = PersistedMediaPath.lookupKeys(for: containerPath).compactMap { all[$0] }.first ?? [:]
        return stored.reduce(into: [:]) { result, entry in
            result[PersistedMediaPath.decode(entry.key)] = entry.value.point(in: canvasSize)
        }
    }

    static func set(
        _ positions: [String: CGPoint],
        in containerPath: String,
        canvasSize: CGSize? = nil,
        defaults: UserDefaults = .standard
    ) {
        var all = load(defaults: defaults)
        let containerKey = normalized(containerPath)
        var containerPositions = all[containerKey] ?? [:]
        for (itemPath, point) in positions {
            containerPositions[normalized(itemPath)] = StoredPoint(point, canvasSize: canvasSize)
        }
        all[containerKey] = containerPositions
        save(all, defaults: defaults)
    }

    static func remove(
        itemPaths: [String],
        from containerPath: String,
        defaults: UserDefaults = .standard
    ) {
        guard !itemPaths.isEmpty else { return }
        var all = load(defaults: defaults)
        let containerKey = normalized(containerPath)
        guard var containerPositions = all[containerKey] else { return }
        for itemPath in itemPaths {
            containerPositions.removeValue(forKey: normalized(itemPath))
        }
        all[containerKey] = containerPositions
        save(all, defaults: defaults)
    }

    private static func load(defaults: UserDefaults) -> [String: [String: StoredPoint]] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: [String: StoredPoint]].self, from: data)
        } catch {
            AppLog.persistence.error("Desktop positions were corrupt and have been reset: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: defaultsKey)
            return [:]
        }
    }

    private static func save(
        _ values: [String: [String: StoredPoint]],
        defaults: UserDefaults
    ) {
        do {
            defaults.set(try JSONEncoder().encode(values), forKey: defaultsKey)
        } catch {
            AppLog.persistence.error("Desktop positions could not be encoded: \(error.localizedDescription, privacy: .public)")
            return
        }
        if !defaults.synchronize() {
            AppLog.persistence.error("Desktop positions could not be flushed to persistent storage.")
        }
    }

    private static func normalized(_ path: String) -> String {
        PersistedMediaPath.encode(path)
    }
}

