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

@Test func directoryErrorsIdentifyTheirPaths() {
    #expect(MeetingTapeError.outDirectoryDoesNotExist("/tmp/missing").description.contains("/tmp/missing"))
    #expect(MeetingTapeError.outPathNotADirectory("/tmp/file").description.contains("/tmp/file"))
}
