import Testing
@testable import TalkText

@MainActor
@Test func packageLoadsCoreEngineTypes() {
    #expect(TranscriptionEngine.maximumRecordingDuration == 300)
}
