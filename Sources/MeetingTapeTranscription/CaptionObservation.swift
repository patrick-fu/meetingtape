import Foundation

public enum CaptionObservationClock {
    public static let producerID = UUID().uuidString.lowercased()
}

public struct CaptionRecognitionObservation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var producerID: String
    public var connectionID: String
    public var segmentID: String
    public var revision: Int
    public var source: TranscriptSource
    public var provider: LiveRecognitionProvider
    public var first: Bool
    public var final: Bool
    public var start: Double
    public var end: Double
    public var audioReadUptime: Double?
    public var receivedUptime: Double
    public var receivedAt: Date
    public var displayedUptime: Double?
    public var displayedAt: Date?

    public var receptionSeconds: Double? { audioReadUptime.flatMap { receivedUptime >= $0 ? receivedUptime - $0 : nil } }
    public var displaySeconds: Double? { displayedUptime.flatMap { shown in audioReadUptime.flatMap { shown >= $0 ? shown - $0 : nil } } }
    public var presentationSeconds: Double? { displayedUptime.flatMap { $0 >= receivedUptime ? $0 - receivedUptime : nil } }
}

extension LiveCaptionStore {
    public func acknowledgeDisplay(_ sessionID: String, segmentID: String, revision: Int, original: Bool, translation: Bool, at date: Date, uptime: Double) throws -> Bool {
        guard uptime.isFinite, let value = try load(sessionID) else { return false }
        var archive = value, changed = false
        if original {
            for index in archive.recognitionObservations.indices {
                let item = archive.recognitionObservations[index]
                if item.segmentID == segmentID, item.revision == revision, item.producerID == CaptionObservationClock.producerID,
                   item.displayedUptime == nil, uptime >= item.receivedUptime {
                    archive.recognitionObservations[index].displayedUptime = uptime
                    archive.recognitionObservations[index].displayedAt = date; changed = true
                }
            }
        }
        if translation, let index = archive.translationJobs.lastIndex(where: { $0.versionID == nil && $0.segmentID == segmentID && $0.revision == revision && $0.state == .succeeded }),
           let attempt = archive.translationJobs[index].attempts.indices.last {
            let item = archive.translationJobs[index].attempts[attempt]
            if item.producerID == CaptionObservationClock.producerID, item.displayedUptime == nil, let received = item.receivedUptime, uptime >= received {
                archive.translationJobs[index].attempts[attempt].displayedUptime = uptime
                archive.translationJobs[index].attempts[attempt].displayedAt = date; changed = true
            }
        }
        if changed { try save(archive) }
        return changed
    }
}
