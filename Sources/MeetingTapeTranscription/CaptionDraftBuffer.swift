import Foundation

struct CaptionDraftBuffer {
    let connectionID: String
    let source: TranscriptSource
    let options: SubtitleOptions
    private var originals: [LiveCaptionSegment] = []
    private(set) var segments: [LiveCaptionSegment] = []

    init(connectionID: String, source: TranscriptSource, options: SubtitleOptions) {
        self.connectionID = connectionID; self.source = source; self.options = options
    }

    mutating func receive(_ values: [LiveCaptionSegment]) -> [LiveCaptionSegment] {
        var originals: [LiveCaptionSegment] = [], visible: [LiveCaptionSegment] = [], changed: [LiveCaptionSegment] = []
        for (index, value) in values.enumerated() {
            var raw = value
            raw.id = "\(connectionID):\(index)"; raw.source = source; raw.connectionID = connectionID
            let old = self.originals.first { $0.id == raw.id }
            let revised = old.map { $0.text != raw.text || $0.start != raw.start || $0.end != raw.end || $0.final != raw.final } ?? true
            raw.revision = (old?.revision ?? 0) + (revised ? 1 : 0)
            var display = raw
            if !options.transcription { display.text = "" }
            if options.translation {
                display.translation = revised ? CaptionTranslation(targetLanguage: options.targetLanguage, state: .pending, provider: options.provider.rawValue) : segments.first { $0.id == raw.id }?.translation
                if revised { changed.append(raw) }
            }
            originals.append(raw); visible.append(display)
        }
        self.originals = originals; segments = visible
        return changed
    }

    mutating func apply(_ response: CaptionTranslation, id: String, revision: Int) -> Bool {
        guard response.targetLanguage == options.targetLanguage,
              let index = segments.firstIndex(where: { $0.id == id && $0.revision == revision }),
              let raw = originals.first(where: { $0.id == id && $0.revision == revision }) else { return false }
        var value = response
        if value.state == .sameLanguage { value.text = options.transcription ? nil : raw.text }
        segments[index].translation = value
        return true
    }

    mutating func discardOriginals() { originals = [] }
}
