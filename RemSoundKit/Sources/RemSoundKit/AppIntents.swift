import AppIntents

/// Shortcuts actions ("App Intents") controlling the receiver: volume up/down, receiving
/// on/off, and mute. Available on iOS and macOS; no entitlement, provisioning, or App
/// Store Connect setup is involved — the actions are extracted into the binary's metadata
/// at build time.
///
/// The intents live in this package, so each app target forwards its `AppIntentsPackage`
/// conformance here (see `RemSoundIOSApp` / `RemSoundMacApp`). Without that registration
/// the metadata extractor never finds them and the actions silently do not appear in the
/// Shortcuts app — a build-time-invisible failure, so don't remove the registrations.
public struct RemSoundKitIntentsPackage: AppIntentsPackage {}

/// All intents mutate the one shared controller the UI observes, on the main actor. When
/// the app isn't running, the system launches it in the background to run the action.
/// Dialogs are plain spoken sentences — Shortcuts and Siri read them aloud, which is the
/// feedback path for the screen-reader users this app is built for.

public struct VolumeUpIntent: AppIntent {
    public static let title: LocalizedStringResource = "Turn Volume Up"
    public static let description = IntentDescription("Raises RemSound's playback volume by 10 percent.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        controller.volume = min(1, controller.volume + 0.1)
        return .result(dialog: "Volume \(Int((controller.volume * 100).rounded())) percent")
    }
}

public struct VolumeDownIntent: AppIntent {
    public static let title: LocalizedStringResource = "Turn Volume Down"
    public static let description = IntentDescription("Lowers RemSound's playback volume by 10 percent.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        controller.volume = max(0, controller.volume - 0.1)
        return .result(dialog: "Volume \(Int((controller.volume * 100).rounded())) percent")
    }
}

public struct SetReceivingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Turn Receiving On or Off"
    public static let description = IntentDescription("Starts or stops listening for RemSound senders.")

    @Parameter(title: "On")
    public var on: Bool

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Turn receiving \(\.$on)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        if on {
            controller.start()
            if let error = controller.lastError {
                return .result(dialog: "Could not start receiving: \(error)")
            }
            return .result(dialog: "Receiving on")
        } else {
            controller.stop()
            return .result(dialog: "Receiving off")
        }
    }
}

public struct SetMutedIntent: AppIntent {
    public static let title: LocalizedStringResource = "Mute or Unmute"
    public static let description = IntentDescription("Mutes or unmutes RemSound's audio playback.")

    @Parameter(title: "Muted")
    public var muted: Bool

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Set muted to \(\.$muted)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        controller.isMuted = muted
        return .result(dialog: muted ? "Audio muted" : "Audio unmuted")
    }
}
