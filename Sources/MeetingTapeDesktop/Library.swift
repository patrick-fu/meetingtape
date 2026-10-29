import AVFoundation
import Foundation
import MeetingTapeCore

struct RecordingItem: Codable, Identifiable, Sendable {
    var snapshot: SessionSnapshot
    var title: String
    var starred = false
    var id: String { snapshot.outputPath ?? snapshot.sessionID }
    var url: URL { URL(fileURLWithPath: id) }
    var date: Date { ISO8601DateFormatter().date(from: snapshot.startedAt) ?? .distantPast }
    var exists: Bool { FileManager.default.fileExists(atPath: id) }
}

struct Waveform: Sendable {
    var system: [Double] = []
    var microphone: [Double] = []

    static func read(_ url: URL) throws -> Waveform {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.processingFormat.channelCount >= 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else {
            throw DesktopFailure(message: "无法读取双声道录音。")
        }
        var result = Waveform()
        for index in 0..<160 {
            try Task.checkCancellation()
            file.framePosition = AVAudioFramePosition(Double(file.length - 1) * Double(index) / 160)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(2048, file.length - file.framePosition)))
            guard let channels = buffer.floatChannelData else { continue }
            var levels = [0.0, 0.0]
            for channel in 0..<2 {
                var peak: Float = 0
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
                levels[channel] = Double(peak)
            }
            result.system.append(levels[0]); result.microphone.append(levels[1])
        }
        return result
    }
}

actor LibraryFiles {
    let directory: URL

    init() {
        directory = ProcessInfo.processInfo.environment["MEETINGTAPE_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape")
    }

    func load() throws -> [RecordingItem] {
        let file = directory.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([RecordingItem].self, from: Data(contentsOf: file))
    }

    func save(_ items: [RecordingItem]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }

    func discover(in directories: [String]) throws -> [SessionSnapshot] {
        var found: [SessionSnapshot] = []
        for directory in Set(directories) {
            let root = URL(fileURLWithPath: directory)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
            for file in children where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("meetingtape-") {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8 * 1_048_576,
                      let data = try? Data(contentsOf: file),
                      let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data), snapshot.schemaVersion == 1,
                      snapshot.state == .completed, let path = snapshot.outputPath,
                      URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == file.deletingPathExtension().appendingPathExtension("m4a").resolvingSymlinksInPath().standardizedFileURL,
                      FileManager.default.fileExists(atPath: path) else { continue }
                found.append(snapshot)
            }
        }
        return found
    }
}

func recordingTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%02d:%02d", value / 60, value % 60)
}

func meterHeight(_ level: Double) -> Double {
    guard level > 0, level.isFinite else { return 0.04 }
    return max(0.04, min(1, (20 * log10(level) + 58) / 58))
}
