@preconcurrency import AppKit
@preconcurrency import UserNotifications
import Foundation

@MainActor
final class EyeRestReminderPresenter: NSObject, UNUserNotificationCenterDelegate {
    private static let notificationIdentifier = "eye-rest-prompt"
    private var notificationCenter: UNUserNotificationCenter?
    private var activeSound: NSSound?
    private var soundTask: Task<Void, Never>?

    func prepareAuthorization() {
        guard let notificationCenter = configuredNotificationCenter() else { return }
        Task { [notificationCenter] in
            let settings = await notificationCenter.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await notificationCenter.requestAuthorization(options: [.alert])
        }
    }

    func presentAutomaticRestPrompt() {
        playRepeatedSound(named: "Tink", volume: 0.75)

        guard let notificationCenter = configuredNotificationCenter() else { return }
        Task { [notificationCenter] in
            let settings = await notificationCenter.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "看向远处 20 秒"
            content.body = "自然眨眼，暂时不要看手机。"
            content.sound = nil

            notificationCenter.removeDeliveredNotifications(
                withIdentifiers: [Self.notificationIdentifier]
            )
            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifier,
                content: content,
                trigger: nil
            )
            try? await notificationCenter.add(request)
        }
    }

    func presentRestFinished() {
        playRepeatedSound(named: "Pop", volume: 0.75)
    }

    private func playRepeatedSound(named name: String, volume: Float) {
        soundTask?.cancel()
        soundTask = Task { @MainActor [weak self] in
            for index in 0 ..< 3 {
                guard !Task.isCancelled, let self else { return }
                self.playSound(named: name, volume: volume)
                if index < 2 {
                    try? await Task.sleep(for: .milliseconds(750))
                }
            }
        }
    }

    private func playSound(named name: String, volume: Float) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        activeSound?.stop()
        sound.volume = volume
        activeSound = sound
        sound.play()
    }

    private func configuredNotificationCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        if let notificationCenter { return notificationCenter }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        notificationCenter = center
        return center
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
