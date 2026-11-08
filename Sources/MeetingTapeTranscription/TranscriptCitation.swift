import Foundation

public struct TranscriptCitation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionID: String?
    public var versionID: String
    public var model: String
    public var source: TranscriptSource
    public var segmentID: String
    public var revision: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: String, sessionID: String? = nil, versionID: String, model: String, source: TranscriptSource, segmentID: String, revision: String, start: Double, end: Double, text: String) {
        self.id = id; self.sessionID = sessionID; self.versionID = versionID; self.model = model; self.source = source
        self.segmentID = segmentID; self.revision = revision; self.start = start; self.end = end; self.text = text
    }
}
