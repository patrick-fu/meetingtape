import Foundation
import MeetingTapeCore

public enum TranscriptSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, microphone, merged

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .system: "系统音频"
        case .microphone: "麦克风"
        case .merged: "合并音源"
        }
    }
    var channel: Int? {
        switch self {
        case .system: 0
        case .microphone: 1
        case .merged: nil
        }
    }
    func segmentID(_ index: Int) -> Int {
        switch self {
        case .system: index * 2
        case .microphone: index * 2 + 1
        case .merged: index
        }
    }
}

public typealias RecognitionMode = MeetingTapeCore.RecognitionMode

extension RecognitionMode {
    public var sources: [TranscriptSource] { self == .separate ? [.system, .microphone] : [.merged] }
}
