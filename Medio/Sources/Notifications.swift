import Foundation
import UserNotifications

@MainActor
protocol NotificationsService {
    func requestAuthorization() async throws -> Bool
    func scheduleLocal(title: String, body: String, after seconds: TimeInterval) async throws
    func cancelAll() async
}

@MainActor
final class MedioNotificationsService: NotificationsService {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func scheduleLocal(title: String, body: String, after seconds: TimeInterval) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: "medio.local.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    func cancelAll() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
