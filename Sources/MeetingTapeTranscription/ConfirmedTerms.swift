import Foundation
import Darwin

public struct ConfirmedTerm: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var canonical: String
    public var aliases: [String]
    public var note: String
    public var translations: [String: String]
    public var preserveOriginal: Bool
    public var references: [TranscriptCitation]

    public init(id: String = UUID().uuidString.lowercased(), canonical: String, aliases: [String] = [], note: String = "", translations: [String: String] = [:], preserveOriginal: Bool = false, references: [TranscriptCitation] = []) {
        self.id = id; self.canonical = canonical; self.aliases = aliases; self.note = note
        self.translations = translations; self.preserveOriginal = preserveOriginal; self.references = references
    }

    public var names: [String] { [canonical] + aliases }
}

public enum ConfirmedTermScope: Sendable, Equatable {
    case global
    case recording(String)
}

public struct ConfirmedTermConflict: Sendable, Equatable {
    public var name: String
    public var termIDs: [String]
    public var scope: ConfirmedTermScope
    public var selectedTermID: String?
}

public struct ConfirmedTermsResolution: Sendable, Equatable {
    public var terms: [ConfirmedTerm]
    public var conflicts: [ConfirmedTermConflict]

    public func glossary(target: String) -> [String: String] {
        let byID = Dictionary(uniqueKeysWithValues: terms.map { ($0.id, $0) })
        let byName = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.name, $0) })
        var result: [String: String] = [:]
        for term in terms {
            for name in term.names {
                let definition: ConfirmedTerm
                if let conflict = byName[confirmedTermKey(name)] {
                    guard let selectedID = conflict.selectedTermID, let selected = byID[selectedID] else { continue }
                    definition = selected
                } else { definition = term }
                if definition.preserveOriginal { result[name] = name }
                else if let translation = definition.translations[target], !translation.isEmpty { result[name] = translation }
            }
        }
        return result
    }
}

public actor ConfirmedTermStore {
    private struct Archive: Codable, Sendable {
        var schemaVersion = 1
        var recordingID: String?
        var terms: [ConfirmedTerm]
        var selections: [String: String]?
        var ignoredSuggestionIDs: [String]?
    }

    private let directory: URL
    private static let maxBytes = 4 * 1_048_576

    public init(directory: URL? = nil) {
        let library = ProcessInfo.processInfo.environment["MEETINGTAPE_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape")
        self.directory = directory ?? library.appendingPathComponent("ConfirmedTerms")
    }

    public nonisolated func load(scope: ConfirmedTermScope) throws -> [ConfirmedTerm] {
        try read(scope).terms
    }

    @discardableResult
    public func save(_ terms: [ConfirmedTerm], scope: ConfirmedTermScope) throws -> ConfirmedTermsResolution {
        try withLock(scope) {
            var archive = try read(scope)
            archive.terms = terms
            let result = try resolution(scope: scope, archive: archive)
            try write(archive, scope: scope)
            return result
        }
    }

    @discardableResult
    public func upsert(_ term: ConfirmedTerm, scope: ConfirmedTermScope) throws -> ConfirmedTermsResolution {
        try withLock(scope) {
            var archive = try read(scope)
            if let index = archive.terms.firstIndex(where: { $0.id == term.id }) { archive.terms[index] = term }
            else { archive.terms.append(term) }
            let result = try resolution(scope: scope, archive: archive)
            try write(archive, scope: scope)
            return result
        }
    }

    @discardableResult
    public func delete(id: String, scope: ConfirmedTermScope) throws -> ConfirmedTermsResolution {
        try withLock(scope) {
            var archive = try read(scope)
            archive.terms.removeAll { $0.id == id }
            archive.selections = archive.selections?.filter { $0.value != id }
            let result = try resolution(scope: scope, archive: archive)
            try write(archive, scope: scope)
            return result
        }
    }

    @discardableResult
    public func select(termID: String?, for name: String, scope: ConfirmedTermScope) throws -> ConfirmedTermsResolution {
        try withLock(scope) {
            var archive = try read(scope)
            let key = confirmedTermKey(name)
            guard !key.isEmpty, key.utf8.count <= 1_024 else { throw TranscriptionFailure("术语选择的名称无效。") }
            if let termID {
                let current = try resolution(scope: scope, archive: archive)
                guard current.terms.contains(where: { $0.id == termID && $0.names.contains(where: { confirmedTermKey($0) == key }) }) else {
                    throw TranscriptionFailure("所选术语不存在或不适用于此名称。")
                }
            }
            var selections = archive.selections ?? [:]
            selections[key] = termID
            archive.selections = selections
            let result = try resolution(scope: scope, archive: archive)
            try write(archive, scope: scope)
            return result
        }
    }

    public nonisolated func ignoredSuggestions(recordingID: String) throws -> Set<String> {
        Set(try read(.recording(recordingID)).ignoredSuggestionIDs ?? [])
    }

    @discardableResult
    public func ignoreSuggestion(id: String, recordingID: String) throws -> Set<String> {
        guard let id = UUID(uuidString: id)?.uuidString.lowercased() else {
            throw TranscriptionFailure("候选术语标识无效。")
        }
        let scope = ConfirmedTermScope.recording(recordingID)
        return try withLock(scope) {
            var archive = try read(scope)
            var ignored = Set(archive.ignoredSuggestionIDs ?? [])
            ignored.insert(id)
            archive.ignoredSuggestionIDs = ignored.sorted()
            try write(archive, scope: scope)
            return ignored
        }
    }

    public nonisolated func effective(recordingID: String? = nil) throws -> ConfirmedTermsResolution {
        let global = try read(.global)
        guard let recordingID else { return resolve(global.terms, scope: .global, selections: global.selections ?? [:]) }
        return merge(global: global, local: try read(.recording(recordingID)), scope: .recording(recordingID))
    }

    private nonisolated func resolution(scope: ConfirmedTermScope, archive: Archive) throws -> ConfirmedTermsResolution {
        switch scope {
        case .global: return resolve(archive.terms, scope: scope, selections: archive.selections ?? [:])
        case .recording: return merge(global: try read(.global), local: archive, scope: scope)
        }
    }

    private nonisolated func merge(global: Archive, local: Archive, scope: ConfirmedTermScope) -> ConfirmedTermsResolution {
        let localNames = Set(local.terms.flatMap(\.names).map(confirmedTermKey))
        let localIDs = Set(local.terms.map(\.id))
        let remaining = global.terms.filter { term in
            !localIDs.contains(term.id) && !term.names.contains { localNames.contains(confirmedTermKey($0)) }
        }
        let selections = (global.selections ?? [:]).merging(local.selections ?? [:]) { _, local in local }
        let globalResolution = resolve(remaining, scope: .global, selections: selections)
        let localResolution = resolve(local.terms, scope: scope, selections: selections)
        return ConfirmedTermsResolution(terms: local.terms + remaining, conflicts: localResolution.conflicts + globalResolution.conflicts)
    }

    private nonisolated func resolve(_ terms: [ConfirmedTerm], scope: ConfirmedTermScope, selections: [String: String]) -> ConfirmedTermsResolution {
        var owners: [String: [String]] = [:]
        for term in terms {
            for name in Set(term.names.map(confirmedTermKey)) { owners[name, default: []].append(term.id) }
        }
        let conflicts = owners.keys.sorted().compactMap { name -> ConfirmedTermConflict? in
            guard let ids = owners[name], ids.count > 1 else { return nil }
            let selected = selections[name].flatMap { ids.contains($0) ? $0 : nil }
            return ConfirmedTermConflict(name: name, termIDs: ids, scope: scope, selectedTermID: selected)
        }
        return ConfirmedTermsResolution(terms: terms, conflicts: conflicts)
    }

    private func withLock<T>(_ scope: ConfirmedTermScope, action: () throws -> T) throws -> T {
        let (path, _) = try location(scope)
        try TranscriptionStore.directory(directory)
        let lock = try TranscriptionLock(path.appendingPathExtension("lock"), wait: true)
        defer { withExtendedLifetime(lock) {} }
        return try action()
    }

    private nonisolated func read(_ scope: ConfirmedTermScope) throws -> Archive {
        let (path, recordingID) = try location(scope)
        guard FileManager.default.fileExists(atPath: path.path) else { return Archive(recordingID: recordingID, terms: []) }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maxBytes else {
            throw TranscriptionFailure("术语文件过大或类型无效，已有内容已保留。")
        }
        let data = try Data(contentsOf: path)
        guard data.count <= Self.maxBytes else { throw TranscriptionFailure("术语文件过大。") }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.schemaVersion == 1, archive.recordingID == recordingID else {
            throw TranscriptionFailure("术语文件版本或录音标识不匹配，已有内容已保留。")
        }
        try validate(archive.terms)
        try validateSelections(archive.selections ?? [:])
        try validateIgnoredSuggestions(archive.ignoredSuggestionIDs ?? [])
        return archive
    }

    private func write(_ archive: Archive, scope: ConfirmedTermScope) throws {
        try validate(archive.terms)
        try validateSelections(archive.selections ?? [:])
        try validateIgnoredSuggestions(archive.ignoredSuggestionIDs ?? [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= Self.maxBytes else { throw TranscriptionFailure("术语已达到单次保存上限，已有内容已保留。") }
        try publish(data, to: location(scope).0)
    }

    private nonisolated func validateSelections(_ selections: [String: String]) throws {
        guard selections.count <= 4_000, selections.allSatisfy({ name, id in
            !name.isEmpty && name.utf8.count <= 1_024 && name == confirmedTermKey(name) && !name.contains("\0") &&
            !id.isEmpty && id.utf8.count <= 128 && !id.contains("\0")
        }) else { throw TranscriptionFailure("术语选择字段无效，已有内容已保留。") }
    }

    private nonisolated func validateIgnoredSuggestions(_ ids: [String]) throws {
        guard ids.count <= 10_000, Set(ids).count == ids.count,
              ids.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }) else {
            throw TranscriptionFailure("已忽略候选术语标识无效或数量超限，已有内容已保留。")
        }
    }

    private nonisolated func location(_ scope: ConfirmedTermScope) throws -> (URL, String?) {
        switch scope {
        case .global: return (directory.appendingPathComponent("global.json"), nil)
        case .recording(let rawID):
            guard let id = UUID(uuidString: rawID)?.uuidString.lowercased() else {
                throw TranscriptionFailure("术语的录音标识无效。")
            }
            return (directory.appendingPathComponent(id + ".json"), id)
        }
    }

    private nonisolated func validate(_ terms: [ConfirmedTerm]) throws {
        func text(_ value: String, max: Int, nonempty: Bool = false) -> Bool {
            value.utf8.count <= max && !value.contains("\0") && (!nonempty || !confirmedTermKey(value).isEmpty)
        }
        guard terms.count <= 2_000, Set(terms.map(\.id)).count == terms.count else {
            throw TranscriptionFailure("术语数量超限或标识重复。")
        }
        for term in terms {
            guard text(term.id, max: 128, nonempty: true), text(term.canonical, max: 1_024, nonempty: true),
                  term.aliases.count <= 64, term.aliases.allSatisfy({ text($0, max: 1_024, nonempty: true) }),
                  text(term.note, max: 8_192), term.translations.count <= 64,
                  term.translations.allSatisfy({ text($0.key, max: 64, nonempty: true) && text($0.value, max: 2_048, nonempty: true) }),
                  term.references.count <= 128,
                  term.references.allSatisfy({ citation in
                      citation.start.isFinite && citation.end.isFinite && citation.start >= 0 && citation.end >= citation.start && citation.end <= 172_800 &&
                      text(citation.id, max: 256, nonempty: true) && text(citation.versionID, max: 256, nonempty: true) &&
                      text(citation.model, max: 256, nonempty: true) && text(citation.segmentID, max: 256, nonempty: true) &&
                      text(citation.revision, max: 256, nonempty: true) && text(citation.text, max: 65_536)
                  }) else { throw TranscriptionFailure("术语字段或原文出处无效，已有内容已保留。") }
        }
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

private func confirmedTermKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
}
