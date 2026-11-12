import CryptoKit
import Foundation

public struct MeetingMinutesSources: Sendable {
    public var citations: [TranscriptCitation]
    public var partial: Bool
    public var missingIntervals: [String]

    public static func load(_ sessionID: String, store: TranscriptionStore? = nil, captions: LiveCaptionStore = LiveCaptionStore()) throws -> Self {
        let snapshot = try TranscriptExportSnapshot.load(sessionID, store: store, captions: captions, includeContent: false)
        var citations: [TranscriptCitation] = []
        var complete = false
        var missing: [String] = []
        func append(versionID: String, model: String, source: TranscriptSource, segmentID: String, revision: String, start: Double, end: Double, text: String) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let identity = try JSONEncoder().encode([sessionID, versionID, source.rawValue, segmentID, revision])
            let id = "s-" + SHA256.hash(data: identity).prefix(8).map { String(format: "%02x", $0) }.joined()
            citations.append(TranscriptCitation(id: id, sessionID: sessionID, versionID: versionID, model: model, source: source, segmentID: segmentID, revision: revision, start: start, end: end, text: text))
        }
        for version in snapshot.versions {
            if let result = version.result {
                if !result.partial, result.unavailableSources.isEmpty, version.run?.state == .succeeded { complete = true }
                for segment in result.segments {
                    try append(versionID: version.id, model: result.model.name, source: segment.source, segmentID: String(segment.id), revision: result.revision, start: segment.start, end: segment.end, text: segment.text)
                }
            }
        }
        if let live = snapshot.versions.first(where: { $0.id == "live" })?.live {
            let translatedVersions = snapshot.versions.filter { $0.id.hasPrefix("live:") }.reversed()
            var unavailable = false
            for segment in live.segments {
                if !segment.text.isEmpty {
                    let model = live.connections.first(where: { $0.id == segment.connectionID })?.modelName ?? live.provider
                    try append(versionID: "live", model: model, source: segment.source, segmentID: segment.id, revision: String(segment.revision), start: segment.start, end: segment.end, text: segment.text)
                } else {
                    let candidates = translatedVersions.compactMap { version -> (String, LiveCaptionSegment)? in
                        guard let value = version.live?.segments.first(where: { $0.id == segment.id }) else { return nil }
                        return (version.id, value)
                    } + [("live", segment)]
                    if let (version, value) = candidates.first(where: { [.translated, .sameLanguage].contains($0.1.translation?.state) && $0.1.targetText != nil }) {
                        try append(versionID: version, model: "目标语言字幕 · " + (value.translation?.provider ?? live.provider), source: value.source, segmentID: value.id, revision: "\(value.revision):\(value.translation?.targetLanguage ?? "")", start: value.start, end: value.end, text: value.targetText ?? "")
                    } else { unavailable = true }
                }
                if !segment.final { unavailable = true }
            }
            let duration = snapshot.duration ?? live.connections.map(\.end).max() ?? 0
            for source in live.recognitionMode.sources {
                let enabled = live.coverage.filter { $0.source == source && $0.state == "enabled" }
                let ranges = live.connections.filter { $0.source == source }.flatMap { connection in
                    enabled.compactMap { interval -> (start: Double, end: Double)? in
                        let start = max(connection.start, interval.start), end = min(connection.end, interval.end)
                        return end > start ? (start, end) : nil
                    }
                }.sorted { $0.start < $1.start }
                var cursor = 0.0
                for range in ranges {
                    if range.start > cursor { missing.append("\(source.name) \(time(cursor))–\(time(range.start))") }
                    cursor = max(cursor, range.end)
                }
                if duration > cursor { missing.append("\(source.name) \(time(cursor))–\(time(duration))") }
            }
            if !live.coverage.isEmpty, missing.isEmpty, !unavailable, !live.connections.isEmpty, live.connections.allSatisfy(\.complete) { complete = true }
        }
        if complete { missing = [] }
        return Self(citations: citations, partial: !complete, missingIntervals: missing)
    }

    private static func time(_ value: Double) -> String {
        let value = Int(max(0, value))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}
