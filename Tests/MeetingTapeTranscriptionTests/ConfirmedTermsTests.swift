import Foundation
import Testing
@testable import MeetingTapeTranscription

@Test func confirmedTermsPreserveSameScopeAmbiguityAndPreferRecordingScope() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-terms-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfirmedTermStore(directory: directory)
    let recordingID = UUID().uuidString.lowercased()
    let first = ConfirmedTerm(canonical: "Alex", aliases: ["负责人"], note: "产品", translations: ["en": "Alex Product"])
    let second = ConfirmedTerm(canonical: "Alex", aliases: ["研究员"], note: "研究", translations: ["en": "Alex Research"])
    let stable = ConfirmedTerm(canonical: "MeetingTape", aliases: ["Meeting 泰普"], preserveOriginal: true)
    let saved = try await store.save([first, second, stable], scope: .global)
    #expect(saved.terms.count == 3)
    #expect(saved.conflicts.count == 1)
    #expect(Set(saved.conflicts[0].termIDs) == Set([first.id, second.id]))
    #expect(saved.glossary(target: "en")["Alex"] == nil)
    #expect(saved.glossary(target: "en")["负责人"] == "Alex Product")
    #expect(saved.glossary(target: "en")["研究员"] == "Alex Research")
    #expect(saved.glossary(target: "en")["Meeting 泰普"] == "Meeting 泰普")

    let local = ConfirmedTerm(canonical: "当前负责人", aliases: ["Alex"], translations: ["en": "Alex Local"])
    try await store.upsert(local, scope: .recording(recordingID))
    let effective = try store.effective(recordingID: recordingID)
    #expect(effective.terms.map(\.id) == [local.id, stable.id])
    #expect(effective.conflicts.isEmpty)
    #expect(effective.glossary(target: "en")["Alex"] == "Alex Local")
    #expect(effective.glossary(target: "ja")["当前负责人"] == nil)
    #expect(try store.load(scope: .global) == [first, second, stable])

    let collision = ConfirmedTerm(canonical: "Alex", translations: ["en": "Other Local"])
    try await store.upsert(collision, scope: .recording(recordingID))
    let ambiguous = try store.effective(recordingID: recordingID)
    #expect(ambiguous.conflicts.count == 1)
    #expect(ambiguous.glossary(target: "en")["Alex"] == nil)
    #expect(ambiguous.glossary(target: "en")["当前负责人"] == "Alex Local")
}

@Test func invalidTermUpdatesAndUnreadableArchivesKeepPreviousBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-terms-preservation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfirmedTermStore(directory: directory)
    let original = ConfirmedTerm(canonical: "MeetingTape", translations: ["en": "MeetingTape"])
    try await store.upsert(original, scope: .global)
    let path = directory.appendingPathComponent("global.json")
    let bytes = try Data(contentsOf: path)
    var invalid = original
    invalid.canonical = String(repeating: "x", count: 1_025)
    await #expect(throws: (any Error).self) { try await store.upsert(invalid, scope: .global) }
    #expect(try Data(contentsOf: path) == bytes)
    await #expect(throws: (any Error).self) { try await store.save([original], scope: .recording("../global")) }
    #expect(try Data(contentsOf: path) == bytes)
    let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(directoryPermissions?.intValue == 0o700)

    let unreadable = Data("{\"schemaVersion\":99,\"terms\":[]}".utf8)
    try unreadable.write(to: path)
    await #expect(throws: (any Error).self) { try await store.upsert(original, scope: .global) }
    #expect(try Data(contentsOf: path) == unreadable)
}

@Test func recordingTermSelectionOverridesGlobalWithoutMovingDefinitions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-terms-selection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfirmedTermStore(directory: directory)
    let recordingID = UUID().uuidString.lowercased()
    let otherRecordingID = UUID().uuidString.lowercased()
    let product = ConfirmedTerm(canonical: "Alex", aliases: ["产品负责人"], translations: ["en": "Alex Product"])
    let research = ConfirmedTerm(canonical: "Alex", aliases: ["研究负责人"], translations: ["en": "Alex Research"])
    try await store.save([product, research], scope: .global)
    let global = try await store.select(termID: product.id, for: "Alex", scope: .global)
    #expect(global.conflicts.first?.selectedTermID == product.id)
    #expect(global.glossary(target: "en")["Alex"] == "Alex Product")
    let local = try await store.select(termID: research.id, for: "Alex", scope: .recording(recordingID))
    #expect(local.conflicts.first?.selectedTermID == research.id)
    #expect(local.glossary(target: "en")["Alex"] == "Alex Research")
    #expect(local.glossary(target: "en")["产品负责人"] == "Alex Product")
    #expect(local.glossary(target: "en")["研究负责人"] == "Alex Research")
    #expect(local.glossary(target: "ja")["Alex"] == nil)
    #expect(try store.load(scope: .recording(recordingID)).isEmpty)
    #expect(try store.load(scope: .global) == [product, research])
    let reopened = ConfirmedTermStore(directory: directory)
    #expect(try reopened.effective(recordingID: recordingID).glossary(target: "en")["Alex"] == "Alex Research")
    #expect(try reopened.effective(recordingID: otherRecordingID).glossary(target: "en")["Alex"] == "Alex Product")
    let cleared = try await store.select(termID: nil, for: "Alex", scope: .recording(recordingID))
    #expect(cleared.glossary(target: "en")["Alex"] == "Alex Product")
    async let firstWrite = store.upsert(ConfirmedTerm(canonical: "并行一"), scope: .recording(otherRecordingID))
    async let secondWrite = reopened.upsert(ConfirmedTerm(canonical: "并行二"), scope: .recording(otherRecordingID))
    _ = try await (firstWrite, secondWrite)
    #expect(try store.load(scope: .recording(otherRecordingID)).count == 2)
    let path = directory.appendingPathComponent(recordingID + ".json")
    let corrupt = Data("{\"schemaVersion\":99,\"terms\":[]}".utf8)
    try corrupt.write(to: path)
    await #expect(throws: (any Error).self) { try await store.select(termID: research.id, for: "Alex", scope: .recording(recordingID)) }
    #expect(try Data(contentsOf: path) == corrupt)
}

@Test func ignoredSuggestionsSurviveTermReplacementWithoutEnteringGlossary() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-ignored-terms-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfirmedTermStore(directory: directory)
    let recordingID = UUID().uuidString.lowercased()
    let suggestionID = UUID().uuidString.lowercased()
    try await store.ignoreSuggestion(id: suggestionID, recordingID: recordingID)
    try await store.save([ConfirmedTerm(canonical: "正式术语", translations: ["en": "Confirmed"])], scope: .recording(recordingID))
    let reopened = ConfirmedTermStore(directory: directory)
    #expect(try reopened.ignoredSuggestions(recordingID: recordingID) == [suggestionID])
    #expect(try reopened.load(scope: .recording(recordingID)).map(\.canonical) == ["正式术语"])
    #expect(try reopened.effective(recordingID: recordingID).glossary(target: "en") == ["正式术语": "Confirmed"])
    let path = directory.appendingPathComponent(recordingID + ".json")
    let corrupt = Data("{\"schemaVersion\":99,\"terms\":[]}".utf8)
    try corrupt.write(to: path)
    await #expect(throws: (any Error).self) { try await store.ignoreSuggestion(id: suggestionID, recordingID: recordingID) }
    #expect(try Data(contentsOf: path) == corrupt)
}
