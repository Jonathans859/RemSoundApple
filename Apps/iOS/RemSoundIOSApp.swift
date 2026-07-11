import AppIntents
import RemSoundKit
import SwiftUI

/// iOS receiver app. The `audio` background mode in Info.plist plus the always-running
/// AVAudioEngine output keep reception alive in the background and on the lock screen.
@main
struct RemSoundIOSApp: App {
    /// Shared instance, not a private one: Shortcuts actions (App Intents) must drive the
    /// same receiver this UI shows.
    private let controller = ReceiverController.shared

    var body: some Scene {
        WindowGroup {
            // ReceiverRootView provides its own NavigationStack (title + About button) and
            // TabView, so it is presented directly here.
            ReceiverRootView(controller: controller)
                .task {
                    controller.start()
                }
        }
    }
}

/// Forwards the metadata extractor to the RemSoundKit package's Shortcuts actions —
/// package-hosted App Intents are invisible without this app-target registration.
extension RemSoundIOSApp: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [RemSoundKitIntentsPackage.self] }
}

/// Ready-made App Shortcuts: a RemSound section in the Shortcuts app (no user setup) and
/// the Siri phrases. Registered with the system at install time — a separate, more reliable
/// path than the action-search index that bare intents rely on. This provider must live in
/// the app target (duplicated in the macOS app), not the package: the phrase-training build
/// step (AppIntentsSSUTraining) reads providers and their literal phrase strings from the
/// app target's sources. Every phrase must contain `\(.applicationName)`.
struct RemSoundAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMuteIntent(),
            phrases: [
                "Mute \(.applicationName)",
                "Unmute \(.applicationName)",
                "Toggle \(.applicationName) mute",
            ],
            shortTitle: "Toggle Mute",
            systemImageName: "speaker.slash"
        )
        AppShortcut(
            intent: VolumeUpIntent(),
            phrases: [
                "Turn up \(.applicationName)",
                "\(.applicationName) volume up",
                "Increase \(.applicationName) volume",
            ],
            shortTitle: "Volume Up",
            systemImageName: "speaker.wave.3"
        )
        AppShortcut(
            intent: VolumeDownIntent(),
            phrases: [
                "Turn down \(.applicationName)",
                "\(.applicationName) volume down",
                "Decrease \(.applicationName) volume",
            ],
            shortTitle: "Volume Down",
            systemImageName: "speaker.wave.1"
        )
        AppShortcut(
            intent: ToggleReceivingIntent(),
            phrases: [
                "Toggle \(.applicationName) receiving",
                "Toggle receiving in \(.applicationName)",
            ],
            shortTitle: "Toggle Receiving",
            systemImageName: "dot.radiowaves.left.and.right"
        )
    }
}
