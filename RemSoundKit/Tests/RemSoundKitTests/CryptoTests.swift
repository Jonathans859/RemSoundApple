import CryptoKit
@testable import RemSoundKit
import XCTest

final class CryptoTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Cross-implementation vectors generated with Python's hashlib.pbkdf2_hmac using the
    /// Windows app's exact parameters (PBKDF2-HMAC-SHA256, 100 000 iterations, fixed salts
    /// "RemSound.v1.audio-key" / "RemSound.v1.fingerprint"). If these ever fail, the Apple
    /// receiver can no longer decrypt Windows senders' audio.
    func testKeyDerivationMatchesWindowsImplementation() {
        XCTAssertEqual(
            hex(RemSoundCrypto.deriveKey(password: "")),
            "e7fe94e96d7cfa6c51ba8e1590f50e37e234e5b0b3e662b24be48a4261f59c18")
        XCTAssertEqual(
            hex(RemSoundCrypto.deriveKey(password: "test123")),
            "b419d5d5ab025172af8ea4f8923ef9176bf2c0e720e40873d82aa4350f0e87d3")
        XCTAssertEqual(
            hex(RemSoundCrypto.deriveKey(password: "correct horse battery staple")),
            "5b105a781f1a3705d9ca53b4cf37014840484f99bb26c29ce22f067f15a12a8d")
    }

    func testFingerprintMatchesWindowsImplementation() {
        XCTAssertEqual(hex(RemSoundCrypto.fingerprint(password: "")), "7a78e2d810154bf7")
        XCTAssertEqual(hex(RemSoundCrypto.fingerprint(password: "test123")), "fb6a9f52926ac190")
        XCTAssertEqual(
            hex(RemSoundCrypto.fingerprint(password: "correct horse battery staple")),
            "c00a33adf9a2555f")
    }

    func testFingerprintsEqual() {
        let a = RemSoundCrypto.fingerprint(password: "test123")
        let b = RemSoundCrypto.fingerprint(password: "test123")
        let c = RemSoundCrypto.fingerprint(password: "other")
        XCTAssertTrue(RemSoundCrypto.fingerprintsEqual(a, b))
        XCTAssertFalse(RemSoundCrypto.fingerprintsEqual(a, c))
        XCTAssertFalse(RemSoundCrypto.fingerprintsEqual(a, Array(a.dropLast())))
    }

    /// Encrypt with CryptoKit, reassemble into the Windows wire layout
    /// `nonce(12) || tag(16) || ciphertext`, and verify AudioDecryptor opens it.
    func testDecryptorOpensWindowsPacketLayout() throws {
        let keyBytes = RemSoundCrypto.deriveKey(password: "test123")
        let plaintext = Array("RemSound audio frame".utf8)

        let sealed = try AES.GCM.seal(Data(plaintext), using: SymmetricKey(data: keyBytes))
        var packet = [UInt8]()
        packet += [UInt8](Data(sealed.nonce))
        packet += [UInt8](sealed.tag)
        packet += [UInt8](sealed.ciphertext)
        XCTAssertEqual(packet.count, plaintext.count + RemSoundCrypto.encryptionOverheadBytes)

        let decryptor = AudioDecryptor()
        XCTAssertFalse(decryptor.hasKey)
        XCTAssertNil(decryptor.tryDecrypt(packet[...])) // mandatory encryption: no key, no audio

        decryptor.ensureKey(keyBytes)
        XCTAssertEqual(decryptor.tryDecrypt(packet[...]), plaintext)
    }

    func testDecryptorRejectsWrongKeyAndTamper() throws {
        let keyBytes = RemSoundCrypto.deriveKey(password: "test123")
        let sealed = try AES.GCM.seal(Data([1, 2, 3, 4]), using: SymmetricKey(data: keyBytes))
        var packet = [UInt8](Data(sealed.nonce)) + [UInt8](sealed.tag) + [UInt8](sealed.ciphertext)

        let decryptor = AudioDecryptor()
        decryptor.ensureKey(RemSoundCrypto.deriveKey(password: "wrong"))
        XCTAssertNil(decryptor.tryDecrypt(packet[...]))

        decryptor.ensureKey(keyBytes)
        XCTAssertNotNil(decryptor.tryDecrypt(packet[...]))
        packet[packet.count - 1] ^= 0xFF // tamper with ciphertext
        XCTAssertNil(decryptor.tryDecrypt(packet[...]))
        XCTAssertNil(decryptor.tryDecrypt(packet[0..<10])) // shorter than overhead
    }
}
