@testable import RemSoundKit
import XCTest

final class PcmAssemblerTests: XCTestCase {
    func testTwoPartAssembly() {
        let assembler = PcmFrameAssembler()
        let part0 = [UInt8](repeating: 0xAA, count: 1000)
        let part1 = [UInt8](repeating: 0xBB, count: 500)
        XCTAssertNil(assembler.assemble(part: part0[...], frameId: 7, partIndex: 0, totalParts: 2))
        let frame = assembler.assemble(part: part1[...], frameId: 7, partIndex: 1, totalParts: 2)
        XCTAssertEqual(frame?.count, 1500)
        XCTAssertEqual(frame?.prefix(1000), ArraySlice(part0))
        XCTAssertEqual(frame?.suffix(500), ArraySlice(part1))
        XCTAssertEqual(assembler.rejectionCount, 0)
        XCTAssertEqual(assembler.discardedPartialCount, 0)
    }

    func testSinglePartFrame() {
        let assembler = PcmFrameAssembler()
        let part = [UInt8]([1, 2, 3])
        XCTAssertEqual(assembler.assemble(part: part[...], frameId: 1, partIndex: 0, totalParts: 1), part)
    }

    func testMissedStartRejected() {
        let assembler = PcmFrameAssembler()
        XCTAssertNil(assembler.assemble(part: [1][...], frameId: 3, partIndex: 1, totalParts: 2))
        XCTAssertEqual(assembler.rejectionCount, 1)
    }

    func testNewFrameDiscardsPartial() {
        let assembler = PcmFrameAssembler()
        XCTAssertNil(assembler.assemble(part: [1][...], frameId: 1, partIndex: 0, totalParts: 2))
        // Next frame starts before part 1 of frame 1 arrived.
        XCTAssertNil(assembler.assemble(part: [2][...], frameId: 2, partIndex: 0, totalParts: 2))
        XCTAssertEqual(assembler.discardedPartialCount, 1)
        let frame = assembler.assemble(part: [3][...], frameId: 2, partIndex: 1, totalParts: 2)
        XCTAssertEqual(frame, [2, 3])
    }
}

final class PcmPackTests: XCTestCase {
    func testInt24Conversion() {
        // 0x7FFFFF = +8388607 → 1.0; 0x800000 = -8388608 → just past -1.0; 0 → 0.
        let bytes: [UInt8] = [
            0xFF, 0xFF, 0x7F, // max positive
            0x00, 0x00, 0x80, // most negative
            0x00, 0x00, 0x00, // zero
            0x01, 0x00, 0x00, // smallest positive step
        ]
        var floats: [Float] = []
        PcmPack.int24LEToFloat(bytes[...], into: &floats)
        XCTAssertEqual(floats.count, 4)
        XCTAssertEqual(floats[0], 1.0, accuracy: 1e-6)
        XCTAssertEqual(floats[1], -8_388_608.0 / 8_388_607.0, accuracy: 1e-6)
        XCTAssertEqual(floats[2], 0.0)
        XCTAssertEqual(floats[3], 1.0 / 8_388_607.0, accuracy: 1e-9)
    }
}

final class SessionPlayoutTests: XCTestCase {
    private func render(_ playout: SessionPlayout, frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames * 2)
        output.withUnsafeMutableBufferPointer { buffer in
            playout.readAdd(into: buffer.baseAddress!, frames: frames)
        }
        return output
    }

    func testStaysSilentUntilTargetReached() {
        let endpoint = UDPEndpoint(host: "127.0.0.1", port: 47830)!
        // 10 ms target = 480 frames at 48 kHz.
        let playout = SessionPlayout(endpoint: endpoint, streamId: 1, targetLatencyMs: 10)

        playout.write([Float](repeating: 0.5, count: 200 * 2), frames: 200)
        XCTAssertTrue(render(playout, frames: 100).allSatisfy { $0 == 0 }, "must not arm below target")

        playout.write([Float](repeating: 0.5, count: 400 * 2), frames: 400)
        let output = render(playout, frames: 100)
        XCTAssertTrue(output.contains { $0 != 0 }, "armed once target latency is buffered")
        // The fade-in ramps the first samples; the steady-state tail must be the raw value.
        XCTAssertEqual(output[199], 0.5, accuracy: 1e-5)
    }

    func testMixAddsToExistingContent() {
        let endpoint = UDPEndpoint(host: "127.0.0.1", port: 47830)!
        let playout = SessionPlayout(endpoint: endpoint, streamId: 1, targetLatencyMs: 5)
        playout.write([Float](repeating: 0.25, count: 480 * 2), frames: 480)

        var output = [Float](repeating: 0.5, count: 64 * 2)
        output.withUnsafeMutableBufferPointer { buffer in
            playout.readAdd(into: buffer.baseAddress!, frames: 64)
        }
        // Past the fade-in window the mix must be 0.5 (pre-existing) + 0.25 (session).
        XCTAssertEqual(output[100], 0.75, accuracy: 1e-5)
    }

    func testUnderrunDisarmsAndRearms() {
        let endpoint = UDPEndpoint(host: "127.0.0.1", port: 47830)!
        let playout = SessionPlayout(endpoint: endpoint, streamId: 1, targetLatencyMs: 5)
        playout.write([Float](repeating: 0.5, count: 240 * 2), frames: 240)
        _ = render(playout, frames: 240) // drain exactly

        // Sustained underrun → concealment then disarm after 8 empty reads.
        for _ in 0..<10 { _ = render(playout, frames: 64) }

        // A trickle below target must NOT restart playback (it would underrun instantly).
        playout.write([Float](repeating: 0.5, count: 60 * 2), frames: 60)
        XCTAssertTrue(render(playout, frames: 32).allSatisfy { $0 == 0 })

        // Refill to target → re-arms.
        playout.write([Float](repeating: 0.5, count: 240 * 2), frames: 240)
        XCTAssertTrue(render(playout, frames: 64).contains { $0 != 0 })
    }
}

final class MixerTests: XCTestCase {
    func testLimiterSoftensPeaksAndMuteSilences() {
        let mixer = PlayoutMixer()
        let endpoint = UDPEndpoint(host: "127.0.0.1", port: 47830)!
        let playout = mixer.getOrCreateSession(endpoint: endpoint, streamId: 1)
        mixer.setTargetLatencyMs(5)

        // Two full-scale sessions would sum to 2.0 — the limiter must keep it under 1.0.
        let playout2 = mixer.getOrCreateSession(endpoint: endpoint, streamId: 2)
        playout.write([Float](repeating: 1.0, count: 480 * 2), frames: 480)
        playout2.write([Float](repeating: 1.0, count: 480 * 2), frames: 480)

        var output = [Float](repeating: 0, count: 128 * 2)
        output.withUnsafeMutableBufferPointer { buffer in
            mixer.render(into: buffer.baseAddress!, frames: 128)
        }
        XCTAssertTrue(output.allSatisfy { abs($0) <= 1.0 })
        XCTAssertGreaterThan(output[200], 0.9, "summed full-scale content should sit near the rail")

        mixer.isMuted = true
        output.withUnsafeMutableBufferPointer { buffer in
            mixer.render(into: buffer.baseAddress!, frames: 128)
        }
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }
}

final class ResamplerTests: XCTestCase {
    func testOutputFrameCountApproximatesRateRatio() {
        let resampler = LinearResampler(inputRate: 44100, outputRate: 48000)
        var output: [Float] = []
        var totalOut = 0
        // Feed 1 second of 44.1 kHz audio in 441-frame packets → expect ~48000 frames out.
        let packet = [Float](repeating: 0.25, count: 441 * 2)
        for _ in 0..<100 {
            totalOut += resampler.process(input: packet, inputFrames: 441, output: &output)
        }
        XCTAssertEqual(Double(totalOut), 48000, accuracy: 100)
    }

    func testPreservesConstantSignal() {
        let resampler = LinearResampler(inputRate: 44100, outputRate: 48000)
        var output: [Float] = []
        let frames = resampler.process(input: [Float](repeating: 0.5, count: 441 * 2), inputFrames: 441, output: &output)
        XCTAssertGreaterThan(frames, 0)
        for i in 0..<(frames * 2) {
            XCTAssertEqual(output[i], 0.5, accuracy: 1e-5)
        }
    }
}
