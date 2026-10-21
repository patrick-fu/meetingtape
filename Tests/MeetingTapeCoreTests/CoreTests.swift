import Foundation
import Testing
@testable import MeetingTapeCore

@Test func exitCodesMatchDocumentedContract() {
    #expect(ExitCode.ok.rawValue == 0)
    #expect(ExitCode.usage.rawValue == 1)
    #expect(ExitCode.environment.rawValue == 2)
    #expect(ExitCode.noActiveSession.rawValue == 3)
    #expect(ExitCode.capture.rawValue == 4)
}

@Test func recordingConfigurationDefaults() {
    let configuration = RecordingConfiguration(outputDirectory: "/tmp/x")
    #expect(configuration.keepRawMicrophone == false)
}

@Test func scaffoldEngineReportsUnavailability() {
    let engine = ScaffoldEngine()
    #expect(throws: MeetingTapeError.captureUnavailable) {
        try engine.start(RecordingConfiguration(outputDirectory: "/tmp"))
    }
    #expect(throws: MeetingTapeError.noActiveSession) {
        try engine.stop()
    }
}
