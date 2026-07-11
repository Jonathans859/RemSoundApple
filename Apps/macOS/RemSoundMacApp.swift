import AppIntents
import RemSoundKit
import SwiftUI

/// macOS receiver app — lives in the menu bar (LSUIElement, no Dock icon), the same role the
/// tray icon plays for the Windows app.
@main
struct RemSoundMacApp: App {
    /// Shared instance, not a private one: Shortcuts actions (App Intents) must drive the
    /// same receiver this UI shows.
    private let controller = ReceiverController.shared

    var body: some Scene {
        MenuBarExtra {
            ReceiverRootView(controller: controller)
                .frame(width: 400, height: 600)
        } label: {
            // The label is installed in the status bar at launch, so its task is our
            // app-did-launch hook: reception starts immediately, not on first menu open.
            Image(systemName: "antenna.radiowaves.left.and.right")
                .task {
                    controller.start()
                }
                .accessibilityLabel("RemSound")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Forwards the metadata extractor to the RemSoundKit package's Shortcuts actions —
/// package-hosted App Intents are invisible without this app-target registration.
extension RemSoundMacApp: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [RemSoundKitIntentsPackage.self] }
}
