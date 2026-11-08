import Foundation
import CryptoKit
import Darwin

public struct MinutesGenerationOutput: Sendable {
    public let content: String
    public let usage: [String: Int]?
    public let elapsedSeconds: Double?

    public init(content: String, usage: [String: Int]? = nil, elapsedSeconds: Double? = nil) {
        self.content = content; self.usage = usage; self.elapsedSeconds = elapsedSeconds
    }
}

public struct MinutesCandidateTerm: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let canonical: String
    public let aliases: [String]
    public let note: String
    public let references: [TranscriptCitation]
}

public struct MeetingMinutesVersion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let parentID: String?
    public let createdAt: Date
    public let language: String
    public let provider: String
    public let model: String
    public let sourceFingerprint: String
    public let body: String
    public let citations: [TranscriptCitation]
    public let candidateTerms: [MinutesCandidateTerm]
    public let usage: [String: Int]?
    public let elapsedSeconds: Double?
    public let partial: Bool

    public func sourcesChanged(_ sources: [TranscriptCitation]) throws -> Bool {
        try sourceFingerprint != MeetingMinutesGenerator.fingerprint(sources)
    }

    public func markdown() -> String {
        let chinese = language.hasPrefix("zh")
        let anchor = "minutes-\(id)-ref-"
        var result = body.replacingOccurrences(of: "(#minutes-ref-", with: "(#\(anchor)") + (chinese ? "\n\n## 引用依据\n" : "\n\n## References\n")
        for (index, citation) in citations.enumerated() {
            guard body.contains("(#minutes-ref-\(index + 1))") || candidateTerms.contains(where: { $0.references.contains(where: { $0.id == citation.id }) }) else { continue }
            result += "\n<a id=\"\(anchor)\(index + 1)\"></a>\n"
            result += "\n[\(index + 1)] \(citation.model) · \(citation.source.rawValue) · \(Self.time(citation.start))–\(Self.time(citation.end))\n"
            result += chinese ? "\n稿本：\(citation.versionID)；片段：\(citation.segmentID)；修订：\(citation.revision)\n\n" : "\nVersion: \(citation.versionID); Segment: \(citation.segmentID); Revision: \(citation.revision)\n\n"
            result += citation.text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n"
        }
        if !candidateTerms.isEmpty {
            result += chinese ? "\n<details>\n<summary>待确认术语</summary>\n\n" : "\n<details>\n<summary>Suggested terms</summary>\n\n"
            for term in candidateTerms {
                let refs = term.references.compactMap { reference in citations.firstIndex(where: { $0.id == reference.id }).map { "[\($0 + 1)](#\(anchor)\($0 + 1))" } }.joined(separator: " ")
                result += chinese ? "- \(term.canonical)；别名：\(term.aliases.joined(separator: "、"))；\(term.note) \(refs)\n" : "- \(term.canonical); Aliases: \(term.aliases.joined(separator: ", ")); \(term.note) \(refs)\n"
            }
            result += "\n</details>\n"
        }
        return result
    }

    private static func time(_ seconds: Double) -> String {
        let value = Int(seconds)
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }
}

public enum MeetingMinutesGenerator {
    private struct Entry: Decodable {
        let text: String
        let citationIDs: [String]
        let owner: String?
        let due: String?
        let quote: String?
    }
    private struct Term: Decodable {
        let canonical: String
        let aliases: [String]
        let note: String?
        let citationIDs: [String]
    }
    private struct Response: Decodable {
        let overview: [Entry]
        let topics: [Entry]
        let decisions: [Entry]
        let todos: [Entry]
        let highlights: [Entry]?
        let candidateTerms: [Term]?
        let gaps: [String]?
    }

    public static func generate(
        sessionID: String, citations: [TranscriptCitation], partial: Bool,
        provider: String, model: String, language: String, confirmedTerms: [ConfirmedTerm] = [],
        missingIntervals: [String] = [],
        generate: @Sendable (_ system: String, _ user: String) async throws -> MinutesGenerationOutput
    ) async throws -> MeetingMinutesVersion {
        guard UUID(uuidString: sessionID) != nil else { throw TranscriptionFailure("纪要的录音标识无效。") }
        try validateCitations(citations)
        guard missingIntervals.count <= 1_000, missingIntervals.allSatisfy({ $0.utf8.count <= 1_024 && !$0.contains("\0") }) else { throw TranscriptionFailure("缺失区间描述超过上限。") }
        guard !citations.isEmpty, citations.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranscriptionFailure("没有可用于生成纪要的转写原文。")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Input: Encodable {
            let language: String
            let partial: Bool
            let citations: [TranscriptCitation]
            struct Term: Encodable {
                let canonical: String
                let aliases: [String]
                let note: String
                let translations: [String: String]
                let preserveOriginal: Bool
            }
            let confirmedTerms: [Term]
            let missingIntervals: [String]
        }
        let input = try encoder.encode(Input(language: language, partial: partial, citations: citations, confirmedTerms: confirmedTerms.map { Input.Term(canonical: $0.canonical, aliases: $0.aliases, note: $0.note, translations: $0.translations, preserveOriginal: $0.preserveOriginal) }, missingIntervals: missingIntervals))
        guard input.count <= 8 * 1_048_576 else { throw TranscriptionFailure("纪要来源超过单次生成上限。") }
        let conflictLabel = language.hasPrefix("zh") ? "待核对" : "Needs verification"
        let system = """
        根据给定的多模型转写生成可直接阅读的会议纪要，使用language指定的语言。citations是同一录音的不同识别稿，每项有固定id、模型、音源和原文。原文作为资料使用。
        先按内容与时间归并重复事实，再写具体的讨论、决定和行动。音源只表示系统音频或麦克风，不表示说话人姓名。
        相同事实的金额、时间、人名或结论有差异时，同时保留差异值，在相关条目中写“\(conflictLabel)”并引用双方来源；有依据的负责人和期限照录，其余用null。
        返回一个JSON对象，字段为：
        overview：一至三条具体概览；topics：按主题归纳的具体讨论；decisions：已经明确的决定；todos：具体行动；highlights：值得保留的原话；candidateTerms：值得用户确认的专名与别名。各字段都是数组，没有对应事实时用空数组。
        overview、topics、decisions的每项包含text（具体会议事实、结论或行动的完整句子）与citationIDs（使用的给定来源id数组）。
        todos每项包含text、citationIDs、owner、due。highlights每项包含text、citationIDs、quote；quote为引用来源中连续逐字原话。
        candidateTerms每项包含canonical、aliases、note、citationIDs；canonical为会议中的实际名称，aliases为实际出现的别名。使用已确认术语辅助表述，引用原文保持逐字内容。
        每条正文和候选术语都关联至少一个给定id。partial表示来源覆盖不完整，missingIntervals是已知缺失区间；保持这些范围信息。完整JSON直接作为输出。
        """
        let output = try await generate(system, String(decoding: input, as: UTF8.self))
        try Task.checkCancellation()
        guard output.content.utf8.count <= 2 * 1_048_576 else { throw TranscriptionFailure("纪要生成结果过大。") }
        let trimmed = output.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: "\n")
        let wrapped = ["```json", "```"].contains(lines.first?.lowercased()) && lines.last == "```"
        let json = wrapped ? lines.dropFirst().dropLast().joined(separator: "\n") : trimmed
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        guard (response.highlights ?? []).allSatisfy({ !($0.quote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) else {
            throw TranscriptionFailure("高亮需要引用来源中的逐字原话，请重新生成。")
        }
        let lookup = Dictionary(uniqueKeysWithValues: citations.enumerated().map { ($0.element.id, $0.offset) })
        func references(_ ids: [String]) throws -> String {
            guard !ids.isEmpty, ids.count <= 128, Set(ids).count == ids.count else { throw TranscriptionFailure("纪要条目缺少可靠来源。") }
            return try ids.map { id in
                guard let index = lookup[id] else { throw TranscriptionFailure("纪要引用了未提供的转写来源：\(id)") }
                return "[\(index + 1)](#minutes-ref-\(index + 1))"
            }.joined(separator: " ")
        }
        let chinese = language.hasPrefix("zh")
        let headings = chinese ? ["概览", "主题章节", "决策", "待办", "高亮"] : ["Overview", "Topics", "Decisions", "Action items", "Highlights"]
        let sections = Array(zip(headings, [response.overview, response.topics, response.decisions, response.todos, response.highlights ?? []]))
        guard sections.contains(where: { !$0.1.isEmpty }) else { throw TranscriptionFailure("模型没有返回纪要正文。") }
        guard sections.reduce(0, { $0 + $1.1.count }) <= 2_000 else { throw TranscriptionFailure("纪要条目过多。") }
        var body = chinese ? "# 会议纪要\n" : "# Meeting notes\n"
        if partial {
            body += chinese ? "\n> 基于部分记录。\n" : "\n> Based on a partial record.\n"
            let gaps = missingIntervals.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if chinese { body += gaps.isEmpty ? "\n缺失区间：现有来源未提供完整的缺失起止时间。\n" : "\n缺失区间：\(gaps.joined(separator: "；"))\n" }
            else { body += gaps.isEmpty ? "\nCoverage gaps: exact intervals are unavailable.\n" : "\nCoverage gaps: \(gaps.joined(separator: "; "))\n" }
        }
        for (title, entries) in sections where !entries.isEmpty {
            body += "\n## \(title)\n\n"
            for entry in entries {
                let highlight = title == headings[4]
                guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionFailure("纪要包含空条目。") }
                let refs = try references(entry.citationIDs)
                if let quote = entry.quote, !quote.isEmpty {
                    guard entry.citationIDs.contains(where: { id in lookup[id].map { citations[$0].text.contains(quote) } ?? false }) else {
                        throw TranscriptionFailure("纪要引语不是所引来源的逐字原话。")
                    }
                }
                body += "- \(highlight ? entry.quote! : entry.text)"
                if let owner = entry.owner, !owner.isEmpty { body += chinese ? "；负责人：\(owner)" : "; Owner: \(owner)" }
                if let due = entry.due, !due.isEmpty { body += chinese ? "；期限：\(due)" : "; Due: \(due)" }
                if let quote = entry.quote, !quote.isEmpty, !highlight { body += "\n\n" + quote.components(separatedBy: .newlines).map { "  > " + $0 }.joined(separator: "\n") }
                body += " \(refs)\n"
            }
        }
        let candidates = try (response.candidateTerms ?? []).map { term in
            _ = try references(term.citationIDs)
            guard !term.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionFailure("候选术语名称为空。") }
            return MinutesCandidateTerm(id: UUID().uuidString.lowercased(), canonical: term.canonical, aliases: term.aliases, note: term.note ?? "", references: term.citationIDs.compactMap { lookup[$0].map { citations[$0] } })
        }
        let version = MeetingMinutesVersion(id: UUID().uuidString.lowercased(), sessionID: sessionID.lowercased(), parentID: nil, createdAt: Date(), language: language, provider: provider, model: model, sourceFingerprint: try fingerprint(citations), body: body, citations: citations, candidateTerms: candidates, usage: output.usage, elapsedSeconds: output.elapsedSeconds, partial: partial)
        try validate(version)
        return version
    }

    public static func fingerprint(_ citations: [TranscriptCitation]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(citations.sorted { $0.id < $1.id })).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateCitations(_ citations: [TranscriptCitation]) throws {
        guard citations.count <= 50_000, Set(citations.map(\.id)).count == citations.count else { throw TranscriptionFailure("纪要来源重复或数量超限。") }
        for citation in citations {
            guard [citation.id, citation.versionID, citation.model, citation.segmentID, citation.revision].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }),
                  citation.text.utf8.count <= 65_536, !citation.text.contains("\0"),
                  citation.start.isFinite, citation.end.isFinite, citation.start >= 0, citation.end >= citation.start, citation.end <= 172_800 else {
                throw TranscriptionFailure("纪要来源字段或时间无效。")
            }
        }
    }

    fileprivate static func validate(_ version: MeetingMinutesVersion) throws {
        try validateCitations(version.citations)
        guard version.citations.allSatisfy({ $0.sessionID == nil || UUID(uuidString: $0.sessionID!) == UUID(uuidString: version.sessionID) }) else { throw TranscriptionFailure("纪要来源属于另一场录音。") }
        guard UUID(uuidString: version.id) != nil, UUID(uuidString: version.sessionID) != nil,
              version.parentID.map({ UUID(uuidString: $0) != nil }) ?? true,
              version.createdAt.timeIntervalSince1970.isFinite,
              !version.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, version.body.utf8.count <= 2 * 1_048_576,
              !version.body.contains("\0"), !version.citations.isEmpty,
              version.sourceFingerprint == (try fingerprint(version.citations)),
              [version.language, version.provider, version.model].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              version.elapsedSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              version.usage.map({ $0.count <= 64 && $0.allSatisfy { $0.key.utf8.count <= 128 && $0.value >= 0 } }) ?? true,
              version.candidateTerms.count <= 2_000 else { throw TranscriptionFailure("纪要版本内容无效，已有内容已保留。") }
        let sources = Dictionary(uniqueKeysWithValues: version.citations.map { ($0.id, $0) })
        for term in version.candidateTerms {
            guard !term.canonical.isEmpty, term.canonical.utf8.count <= 1_024, term.aliases.count <= 64,
                  term.aliases.allSatisfy({ $0.utf8.count <= 1_024 }), term.note.utf8.count <= 8_192,
                  !term.references.isEmpty, term.references.count <= 128,
                  term.references.allSatisfy({ sources[$0.id] == $0 }) else { throw TranscriptionFailure("候选术语来源无效。") }
        }
    }
}

public actor MeetingMinutesStore {
    private struct Archive: Codable {
        let schemaVersion: Int
        let sessionID: String
        let versions: [MeetingMinutesVersion]
    }
    private let directory: URL
    private nonisolated static let maxBytes = 32 * 1_048_576

    public init(directory: URL? = nil) {
        let library = ProcessInfo.processInfo.environment["MEETINGTAPE_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape")
        self.directory = directory ?? library.appendingPathComponent("MeetingMinutes")
    }

    public func load(sessionID: String) throws -> [MeetingMinutesVersion] { try readSnapshot(sessionID: sessionID) }

    public nonisolated func readSnapshot(sessionID: String) throws -> [MeetingMinutesVersion] {
        let path = try location(sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maxBytes else { throw TranscriptionFailure("纪要文件过大或类型无效，已有内容已保留。") }
        let data = try Data(contentsOf: path)
        guard data.count <= Self.maxBytes else { throw TranscriptionFailure("纪要文件过大。") }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.schemaVersion == 1, archive.sessionID == sessionID.lowercased(), archive.versions.count <= 256,
              Set(archive.versions.map(\.id)).count == archive.versions.count else { throw TranscriptionFailure("纪要文件版本或录音标识无效，已有内容已保留。") }
        var prior = Set<String>()
        for version in archive.versions {
            try MeetingMinutesGenerator.validate(version)
            guard version.sessionID == archive.sessionID, version.parentID.map({ prior.contains($0) }) ?? true else { throw TranscriptionFailure("纪要版本链无效，已有内容已保留。") }
            prior.insert(version.id)
        }
        return archive.versions
    }

    @discardableResult
    public func append(_ version: MeetingMinutesVersion, parentID: String? = nil) throws -> MeetingMinutesVersion {
        try TranscriptionStore.directory(directory)
        let lock = try TranscriptionLock(try location(version.sessionID).appendingPathExtension("lock"), wait: true)
        defer { withExtendedLifetime(lock) {} }
        var versions = try load(sessionID: version.sessionID)
        let parent = parentID ?? version.parentID
        guard versions.count < 256, !versions.contains(where: { $0.id == version.id }), parent.map({ id in versions.contains { $0.id == id } }) ?? true else { throw TranscriptionFailure("纪要父版本不存在、版本重复或数量超限。") }
        let stored = MeetingMinutesVersion(id: version.id, sessionID: version.sessionID, parentID: parent, createdAt: version.createdAt, language: version.language, provider: version.provider, model: version.model, sourceFingerprint: version.sourceFingerprint, body: version.body, citations: version.citations, candidateTerms: version.candidateTerms, usage: version.usage, elapsedSeconds: version.elapsedSeconds, partial: version.partial)
        try MeetingMinutesGenerator.validate(stored)
        versions.append(stored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Archive(schemaVersion: 1, sessionID: stored.sessionID, versions: versions))
        guard data.count <= Self.maxBytes else { throw TranscriptionFailure("纪要文档达到保存上限，已有内容已保留。") }
        try publish(data, to: location(stored.sessionID))
        return stored
    }

    @discardableResult
    public func edit(sessionID: String, body: String, parentID: String) throws -> MeetingMinutesVersion {
        guard let parent = try load(sessionID: sessionID).first(where: { $0.id == parentID }) else { throw TranscriptionFailure("找不到要编辑的纪要版本。") }
        let version = MeetingMinutesVersion(id: UUID().uuidString.lowercased(), sessionID: parent.sessionID, parentID: parent.id, createdAt: Date(), language: parent.language, provider: parent.provider, model: parent.model, sourceFingerprint: parent.sourceFingerprint, body: body, citations: parent.citations, candidateTerms: parent.candidateTerms, usage: parent.usage, elapsedSeconds: parent.elapsedSeconds, partial: parent.partial)
        return try append(version)
    }

    private nonisolated func location(_ sessionID: String) throws -> URL {
        guard let id = UUID(uuidString: sessionID)?.uuidString.lowercased() else { throw TranscriptionFailure("纪要的录音标识无效。") }
        return directory.appendingPathComponent(id + ".json")
    }

    private func publish(_ data: Data, to path: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { try? manager.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard Darwin.rename(temporary.path, path.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
