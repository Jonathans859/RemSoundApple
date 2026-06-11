import AVFAudio
import Foundation

/// Renders the mix bus through AVAudioEngine via an AVAudioSourceNode pulling 48 kHz
/// interleaved stereo float32 from the `PlayoutMixer`.
///
/// iOS specifics: configures an AVAudioSession with the `.playback` category (which, combined
/// with the `audio` background mode in the app's Info.plist, keeps audio running with the
/// screen locked or the app in the background) and asks for a short IO buffer for low output
/// latency. Interruptions (calls, Siri) and media-services resets restart the engine.
public final class AudioOutput {
    private let mixer: PlayoutMixer
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []

    public var onDiagnostic: ((String) -> Void)?
    public private(set) var isRunning = false

    public init(mixer: PlayoutMixer) {
        self.mixer = mixer
    }

    public func start() throws {
        guard !isRunning else { return }

#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        // 48 kHz to match the wire mix rate; ~5 ms IO buffer for low output latency. Both
        // are preferences — the OS may give us less aggressive values on some routes.
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        installSessionObservers()
#endif

        let engine = AVAudioEngine()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!

        let source = AVAudioSourceNode(format: format) { [mixer] _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first, let data = buffer.mData else { return noErr }
            mixer.render(into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        self.engine = engine
        self.sourceNode = source
        isRunning = true
        onDiagnostic?("audio output started")
    }

    public func stop() {
        guard isRunning else { return }
        engine?.stop()
        if let source = sourceNode { engine?.detach(source) }
        engine = nil
        sourceNode = nil
        isRunning = false
#if os(iOS)
        removeSessionObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
        onDiagnostic?("audio output stopped")
    }

#if os(iOS)
    private func installSessionObservers() {
        removeSessionObservers()
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            switch type {
            case .began:
                self.engine?.pause()
                self.onDiagnostic?("audio interrupted")
            case .ended:
                let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    try? self.engine?.start()
                    self.onDiagnostic?("audio resumed after interruption")
                }
            @unknown default:
                break
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Media services daemon restarted — all audio objects are invalid; rebuild.
            guard let self, self.isRunning else { return }
            self.onDiagnostic?("media services reset — restarting audio")
            self.isRunning = false
            self.engine = nil
            self.sourceNode = nil
            try? self.start()
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Headphones unplugged / AirPods connected etc. The engine usually survives, but
            // if the route change stopped it, kick it back into life.
            guard let self, self.isRunning, let engine = self.engine, !engine.isRunning else { return }
            try? engine.start()
            self.onDiagnostic?("audio restarted after route change")
        })
    }

    private func removeSessionObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
#endif
}
