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
