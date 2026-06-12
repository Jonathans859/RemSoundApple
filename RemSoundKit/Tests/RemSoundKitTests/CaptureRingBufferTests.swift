import AVFAudio
@testable import RemSoundKit
import XCTest

/// Covers the SPSC ring that hands capture audio from the realtime sink-node block to
/// the drain thread. The AVAudioEngine / AVAudioSinkNode capture path itself is not
/// CI-testable (no audio hardware on runners); these tests pin the interleaving, wrap,
/// overflow, and cross-thread visibility behaviour the realtime path relies on.
final class CaptureRingBufferTests: XCTestCase {
    private func readFrames(_ ring: CaptureRingBuffer, _ frames: Int) -> [Float]? {
        var out = [Float](repeating: 0, count: frames * ring.channels)
        let ok = out.withUnsafeMutableBufferPointer { buffer in
            ring.read(into: buffer.baseAddress!, frames: frames)
        }
        return ok ? out : nil
    }

    func testInterleavedRoundTripAcrossWraparound() {
        // 32-frame stereo ring (64 floats, already a power of two). Write/read 24-frame
        // chunks repeatedly so the indices wrap several times mid-chunk.
        let ring = CaptureRingBuffer(capacityFrames: 32, channels: 2)
        var next: Float = 0
        for _ in 0..<10 {
            var chunk = [Float]()
            for f in 0..<24 {
                chunk.append(next + Float(f) * 2)       // left
                chunk.append(-(next + Float(f) * 2))    // right = negated left
            }
            chunk.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frames: 24) }

            guard let out = readFrames(ring, 24) else { return XCTFail("read failed") }
            XCTAssertEqual(out, chunk, "stream must survive wraparound intact")
            // Left/right must not swap across the wrap seam.
            for f in 0..<24 {
                XCTAssertEqual(out[f * 2], -out[f * 2 + 1], "channel alignment lost at frame \(f)")
            }
            next += 48
        }
        XCTAssertEqual(ring.droppedFrames, 0)
    }

    func testDeinterleavedBufferListInterleavesInOrder() {
        let ring = CaptureRingBuffer(capacityFrames: 64, channels: 2)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)! // deinterleaved
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        let left: [Float] = [1, 2, 3]
        let right: [Float] = [10, 20, 30]
        for i in 0..<3 {
            buffer.floatChannelData![0][i] = left[i]
            buffer.floatChannelData![1][i] = right[i]
        }

        ring.write(bufferList: buffer.audioBufferList, frames: 3)
        XCTAssertEqual(ring.availableFrames, 3)
        XCTAssertEqual(ring.lastChunkFrames, 3)
        XCTAssertEqual(readFrames(ring, 3), [1, 10, 2, 20, 3, 30])
    }

    func testInterleavedSingleBufferListPassesThrough() {
        let ring = CaptureRingBuffer(capacityFrames: 64, channels: 2)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let samples: [Float] = [1, -1, 2, -2]
        for i in 0..<4 { buffer.floatChannelData![0][i] = samples[i] }

        ring.write(bufferList: buffer.audioBufferList, frames: 2)
        XCTAssertEqual(readFrames(ring, 2), samples)
    }

    func testOverflowDropsIncomingBlockAndKeepsExisting() {
        // Exactly 16 stereo frames of capacity.
        let ring = CaptureRingBuffer(capacityFrames: 16, channels: 2)
        let first = (0..<20).map(Float.init) // 10 frames
        first.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frames: 10) }

        // 10 more frames don't fit (only 6 free) — the whole incoming block must drop.
        let second = [Float](repeating: 99, count: 20)
        second.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frames: 10) }

        XCTAssertEqual(ring.droppedFrames, 10)
        XCTAssertEqual(ring.availableFrames, 10, "existing data must be untouched")
        XCTAssertEqual(readFrames(ring, 10), first)
        XCTAssertNil(readFrames(ring, 1), "ring must be empty after draining the survivor")
    }

    func testReadRefusesShortBuffer() {
        let ring = CaptureRingBuffer(capacityFrames: 16, channels: 2)
        let chunk: [Float] = [1, 2, 3, 4] // 2 frames
        chunk.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frames: 2) }
        XCTAssertNil(readFrames(ring, 3), "read must be all-or-nothing")
        XCTAssertEqual(readFrames(ring, 2), chunk, "refused read must consume nothing")
    }

    func testConcurrentProducerConsumerPreservesStream() {
        // Mono ramp pushed from a producer thread in odd-sized chunks while this thread
        // consumes whatever is available; the consumed stream must be the exact ramp.
        // The ring is sized for the whole stream so scheduling can never force a drop.
        let total = 10_000
        let ring = CaptureRingBuffer(capacityFrames: total, channels: 1)
        let ramp = (0..<total).map(Float.init)

        let producer = Thread {
            var sent = 0
            var chunk = 1
            while sent < total {
                let n = min(chunk, total - sent)
                ramp.withUnsafeBufferPointer { buffer in
                    ring.writeInterleaved(buffer.baseAddress! + sent, frames: n)
                }
                sent += n
                chunk = chunk % 37 + 1 // 1…37, co-prime-ish with everything
            }
        }
        producer.start()

        var consumed = [Float]()
        consumed.reserveCapacity(total)
        let deadline = Date().addingTimeInterval(10)
        while consumed.count < total && Date() < deadline {
            let available = min(ring.availableFrames, total - consumed.count)
            if available == 0 { continue }
            if let out = readFrames(ring, available) {
                consumed.append(contentsOf: out)
            }
        }

        XCTAssertEqual(consumed.count, total, "consumer timed out — visibility/index bug")
        XCTAssertEqual(consumed, ramp, "stream must arrive in order and uncorrupted")
        XCTAssertEqual(ring.droppedFrames, 0)
    }
}
