import Foundation
import XCTest
@testable import TalkText

final class TranscriptionCoreTests: XCTestCase {
    func testRecordedAudioValidatorChecksExistenceSizeFormatAndUsefulDuration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TalkText-AudioValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingURL = root.appendingPathComponent("missing.wav")
        let emptyURL = root.appendingPathComponent("empty.wav")
        let corruptURL = root.appendingPathComponent("corrupt.wav")
        let shortURL = root.appendingPathComponent("short.wav")
        let validURL = root.appendingPathComponent("valid.wav")
        let longURL = root.appendingPathComponent("long.wav")
        FileManager.default.createFile(atPath: emptyURL.path, contents: Data())
        try Data("not audio".utf8).write(to: corruptURL)
        try writeSilentWAV(to: shortURL, duration: 0.02)
        try writeSilentWAV(to: validURL, duration: 0.12)
        try writeSilentWAV(to: longURL, duration: 0.3)

        let validator = RecordedAudioValidator(
            minimumUsefulDuration: 0.05,
            maximumUsefulDuration: 0.2
        )

        XCTAssertEqual(validator.validateAudio(at: missingURL), .invalid(.missing))
        XCTAssertEqual(validator.validateAudio(at: emptyURL), .invalid(.empty))
        XCTAssertEqual(validator.validateAudio(at: corruptURL), .invalid(.unreadableFormat))
        guard case .invalid(.tooShort) = validator.validateAudio(at: shortURL) else {
            return XCTFail("Expected short audio rejection")
        }
        guard case let .valid(duration) = validator.validateAudio(at: validURL) else {
            return XCTFail("Expected valid audio")
        }
        XCTAssertEqual(duration, 0.12, accuracy: 0.01)
        guard case .invalid(.tooLong) = validator.validateAudio(at: longURL) else {
            return XCTFail("Expected long audio rejection")
        }
    }

    func testActiveWAVSnapshotRepairsStaleHeaderAndDropsIncompleteFrame() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TalkText-LiveSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("active.wav")
        let snapshotURL = root.appendingPathComponent("snapshot.wav")
        try writeSilentWAV(to: sourceURL, duration: 0.12)

        var activeData = try Data(contentsOf: sourceURL)
        let completeFileSize = activeData.count
        overwriteLittleEndian(UInt32(0), in: &activeData, at: 4)
        overwriteLittleEndian(UInt32(0), in: &activeData, at: 40)
        activeData.append(0x7f)
        try activeData.write(to: sourceURL)

        let created = await ActiveWAVRecordingSnapshotter().createSnapshot(
            from: sourceURL,
            at: snapshotURL
        )

        XCTAssertTrue(created)
        let snapshotData = try Data(contentsOf: snapshotURL)
        XCTAssertEqual(snapshotData.count, completeFileSize)
        XCTAssertEqual(readLittleEndianUInt32(in: snapshotData, at: 4), UInt32(completeFileSize - 8))
        XCTAssertEqual(readLittleEndianUInt32(in: snapshotData, at: 40), UInt32(completeFileSize - 44))
        guard case let .valid(duration) = RecordedAudioValidator().validateAudio(at: snapshotURL) else {
            return XCTFail("Expected the repaired preview to be readable audio")
        }
        XCTAssertEqual(duration, 0.12, accuracy: 0.01)

        let unchangedSource = try Data(contentsOf: sourceURL)
        XCTAssertEqual(readLittleEndianUInt32(in: unchangedSource, at: 4), 0)
        XCTAssertEqual(readLittleEndianUInt32(in: unchangedSource, at: 40), 0)
    }

    func testActiveWAVSnapshotRejectsIncompleteOrNonWAVInput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TalkText-InvalidLiveSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("active.wav")
        let snapshotURL = root.appendingPathComponent("snapshot.wav")
        try Data("not an active wave file".utf8).write(to: sourceURL)

        let created = await ActiveWAVRecordingSnapshotter().createSnapshot(
            from: sourceURL,
            at: snapshotURL
        )

        XCTAssertFalse(created)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testTranscriptClassifierPreservesLiteralCodeAndBlankMarkers() {
        XCTAssertEqual(TranscriptOutputClassifier.clean("  getUserByID != nil; [BLANK_AUDIO] \n"), "getUserByID != nil; [BLANK_AUDIO]")
    }

    private func writeSilentWAV(to url: URL, duration: TimeInterval) throws {
        let sampleRate: UInt32 = 16_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let frameCount = UInt32(duration * Double(sampleRate))
        let blockAlign = channelCount * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let audioByteCount = frameCount * UInt32(blockAlign)

        var data = Data("RIFF".utf8)
        appendLittleEndian(36 + audioByteCount, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channelCount, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(blockAlign, to: &data)
        appendLittleEndian(bitsPerSample, to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(audioByteCount, to: &data)
        data.append(Data(repeating: 0, count: Int(audioByteCount)))
        try data.write(to: url)
    }

    private func appendLittleEndian(_ value: some FixedWidthInteger, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func overwriteLittleEndian(_ value: UInt32, in data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func readLittleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
