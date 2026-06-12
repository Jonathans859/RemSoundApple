import AVFAudio
import Synchronization

/// Lock-free SPSC ring buffer carrying hardware-format float samples from the realtime
/// capture render block (producer) to the drain thread (consumer).
///
/// Contract:
///   * Exactly ONE producer thread calls `write*` / exactly ONE consumer calls `read`.
///   * The producer never moves the read index — when the ring lacks space the INCOMING
///     block is dropped whole (drop-newest) and counted; anything else would race the
///     consumer's in-progress copy.
///   * `writeCount` / `readCount` are monotonically increasing float counters (64-bit on
///     all our platforms — they never wrap in practice); the masked index derives from
///     them, so capacity is a power of two and wrap math is a single AND.
///   * Producer-side code is realtime-safe: no locks, no allocation, no ObjC messaging.
///
/// `Synchronization.Atomic` is first-party and lock-free; its availability floor
/// (iOS 18 / macOS 15) is exactly this package's platform minimum. Keep all atomics
/// usage confined to this file (the documented fallback, should a toolchain reject the
/// import, is fixed-signature C wrappers in RemOpusShim).
final class CaptureRingBuffer: @unchecked Sendable {
    let channels: Int

    private let storage: UnsafeMutablePointer<Float>
    private let capacityFloats: Int // power of two
    private let mask: Int

    /// Total floats ever written / read. Producer owns writeCount, consumer owns readCount.
    private let writeCount = Atomic<Int>(0)
    private let readCount = Atomic<Int>(0)

    /// Diagnostics. Both are written only by the producer (single-writer, relaxed is enough).
    private let droppedFramesCounter = Atomic<Int>(0)
    private let lastChunkFramesValue = Atomic<Int>(0)

    init(capacityFrames: Int, channels: Int) {
        self.channels = max(1, channels)
        let floats = max(self.channels, capacityFrames * self.channels)
        var pow2 = 1
        while pow2 < floats { pow2 <<= 1 }
        capacityFloats = pow2
        mask = pow2 - 1
        storage = UnsafeMutablePointer<Float>.allocate(capacity: pow2)
        storage.initialize(repeating: 0, count: pow2)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: - Producer side (realtime thread)

    /// Interleaves an `AudioBufferList` (one plane per channel, or a single already-
    /// interleaved buffer) into the ring. Drops the whole block when space is short.
    func write(bufferList list: UnsafePointer<AudioBufferList>, frames: Int) {
        lastChunkFramesValue.store(frames, ordering: .relaxed)
        let floats = frames * channels
        let write = writeCount.load(ordering: .relaxed) // producer-owned
        let read = readCount.load(ordering: .acquiring)
        if capacityFloats - (write - read) < floats {
            let dropped = droppedFramesCounter.load(ordering: .relaxed)
            droppedFramesCounter.store(dropped + frames, ordering: .relaxed)
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        if buffers.count == 1 {
            guard let data = buffers[0].mData else { return }
            let src = data.assumingMemoryBound(to: Float.self)
            for i in 0..<floats {
                storage[(write + i) & mask] = src[i]
            }
        } else {
            for channel in 0..<channels {
                let plane = buffers[min(channel, buffers.count - 1)].mData?
                    .assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    storage[(write + frame * channels + channel) & mask] = plane?[frame] ?? 0
                }
            }
        }
        writeCount.store(write + floats, ordering: .releasing)
    }

    /// Already-interleaved producer write (also the single-buffer path's logic; kept
    /// separate so tests can drive the ring without constructing AudioBufferLists).
    func writeInterleaved(_ src: UnsafePointer<Float>, frames: Int) {
        lastChunkFramesValue.store(frames, ordering: .relaxed)
        let floats = frames * channels
        let write = writeCount.load(ordering: .relaxed)
        let read = readCount.load(ordering: .acquiring)
        if capacityFloats - (write - read) < floats {
            let dropped = droppedFramesCounter.load(ordering: .relaxed)
            droppedFramesCounter.store(dropped + frames, ordering: .relaxed)
            return
        }
        for i in 0..<floats {
            storage[(write + i) & mask] = src[i]
        }
        writeCount.store(write + floats, ordering: .releasing)
    }

    // MARK: - Consumer side (drain thread)

    /// Copies exactly `frames` interleaved frames into `dst`. Returns false (touching
    /// nothing) when fewer frames are buffered.
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        let floats = frames * channels
        let read = readCount.load(ordering: .relaxed) // consumer-owned
        let write = writeCount.load(ordering: .acquiring)
        guard write - read >= floats else { return false }
        for i in 0..<floats {
            dst[i] = storage[(read + i) & mask]
        }
        readCount.store(read + floats, ordering: .releasing)
        return true
    }

    /// Whole frames currently buffered (consumer view; producers see a lower bound).
    var availableFrames: Int {
        (writeCount.load(ordering: .acquiring) - readCount.load(ordering: .relaxed)) / channels
    }

    // MARK: - Diagnostics

    /// Hardware frames dropped because the consumer fell behind the 400 ms capacity.
    var droppedFrames: Int { droppedFramesCounter.load(ordering: .relaxed) }

    /// Size of the most recent producer write, in frames (the capture callback quantum).
    var lastChunkFrames: Int { lastChunkFramesValue.load(ordering: .relaxed) }
}
