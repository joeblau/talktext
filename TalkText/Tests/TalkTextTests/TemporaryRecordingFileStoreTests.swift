import Foundation
import XCTest
@testable import TalkText

@MainActor
final class TemporaryRecordingFileStoreTests: XCTestCase {
    func testEveryRecordingGetsCollisionResistantURLAndTerminalCleanup() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TemporaryRecordingFileStore(temporaryDirectory: root)

        let first = try store.allocateRecordingURL()
        let second = try store.allocateRecordingURL()
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        XCTAssertTrue(first.lastPathComponent.hasPrefix("recording-"))

        try store.removeRecording(at: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

        try store.cleanupInstance()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testConcurrentInstancesCannotDeleteEachOthersRecordings() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = try TemporaryRecordingFileStore(
            temporaryDirectory: root,
            instanceIdentifier: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let secondStore = try TemporaryRecordingFileStore(
            temporaryDirectory: root,
            instanceIdentifier: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let firstURL = try firstStore.allocateRecordingURL()
        let secondURL = try secondStore.allocateRecordingURL()
        try Data("one".utf8).write(to: firstURL)
        try Data("two".utf8).write(to: secondURL)

        XCTAssertThrowsError(try firstStore.removeRecording(at: secondURL)) { error in
            XCTAssertEqual(error as? RecordingFileStoreError, .outOfScopeURL)
        }
        try firstStore.cleanupInstance()

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testStartupCleanupOnlyRemovesOldTalkTextOwnedInstanceDirectories() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root
            .appendingPathComponent("TalkText", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        let oldOwned = recordingsRoot.appendingPathComponent("instance-old", isDirectory: true)
        let recentOwned = recordingsRoot.appendingPathComponent("instance-recent", isDirectory: true)
        let oldUnowned = recordingsRoot.appendingPathComponent("unowned-old", isDirectory: true)
        for directory in [oldOwned, recentOwned, oldUnowned] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: directory.appendingPathComponent("recording-fixture.wav"))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-48 * 60 * 60)],
            ofItemAtPath: oldOwned.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-48 * 60 * 60)],
            ofItemAtPath: oldUnowned.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: recentOwned.path
        )
        let store = try TemporaryRecordingFileStore(
            temporaryDirectory: root,
            instanceIdentifier: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            now: { now }
        )

        try store.removeStaleOwnedFiles(olderThan: 24 * 60 * 60)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOwned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentOwned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldUnowned.path))
    }

    func testCleanupIsIdempotentForMissingRecordingAndInstance() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TemporaryRecordingFileStore(temporaryDirectory: root)
        let url = try store.allocateRecordingURL()

        XCTAssertNoThrow(try store.removeRecording(at: url))
        XCTAssertNoThrow(try store.cleanupInstance())
        XCTAssertNoThrow(try store.cleanupInstance())
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TalkText-FileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
