import MeetingTapeTranscription
import SwiftUI

struct ConfirmedTermsView: View {
    let sessionID: String?
    var candidates: [MinutesCandidateTerm] = []
    var onLocate: (TranscriptCitation) -> Void = { _ in }
    var onChange: () -> Void = {}
    @State private var entries: [TermEntry] = []
    @State private var conflicts: [ConfirmedTermConflict] = []
    @State private var effective: [ConfirmedTerm] = []
    @State private var ignored: Set<String> = []
    @State private var query = ""
    @State private var editor: TermDraft?
    @State private var message: String?
    @State private var mutating = false
    private let store = ConfirmedTermStore()

    private var visible: [TermEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            needle.isEmpty || ([entry.term.canonical, entry.term.note] + entry.term.aliases).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }
    private var pending: [MinutesCandidateTerm] {
        let confirmed = Set(entries.map { $0.term.id })
        return candidates.filter { !ignored.contains($0.id) && !confirmed.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(sessionID == nil ? "全局词库" : "人名与术语").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { editor = TermDraft(term: ConfirmedTerm(canonical: ""), global: sessionID == nil) } label: {
                    Label("添加术语", systemImage: "plus")
                }.controlSize(.small).disabled(mutating)
            }
            TextField("搜索名称、别名或备注", text: $query).textFieldStyle(.roundedBorder)
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            if !conflicts.isEmpty { conflictsView }
            if visible.isEmpty {
                Text(query.isEmpty ? "尚无已确认术语" : "未找到匹配的术语").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(visible) { entry in
                    termRow(entry)
                    Divider()
                }
            }
            if sessionID != nil, !pending.isEmpty {
                DisclosureGroup("待确认（\(pending.count)）") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(pending) { candidate in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(candidate.canonical).font(.system(size: 14, weight: .medium))
                                if !candidate.aliases.isEmpty { Text(candidate.aliases.joined(separator: "、")).font(.system(size: 12)).foregroundStyle(.secondary) }
                                if !candidate.note.isEmpty { Text(candidate.note).font(.system(size: 12)).textSelection(.enabled) }
                                references(candidate.references)
                                HStack {
                                    Button("编辑后确认") {
                                        editor = TermDraft(term: ConfirmedTerm(id: candidate.id, canonical: candidate.canonical, aliases: candidate.aliases, note: candidate.note, references: candidate.references), global: false)
                                    }
                                    Button("忽略") { ignore(candidate) }
                                }.controlSize(.small).disabled(mutating)
                            }
                            Divider()
                        }
                    }.padding(.top, 12)
                }
            }
        }
        .task(id: sessionID) { entries = []; conflicts = []; effective = []; ignored = []; message = nil; editor = nil; reload() }
        .onChange(of: candidates) { _, _ in reload() }
        .sheet(item: $editor) { draft in
            TermEditorView(draft: draft, allowsLocal: sessionID != nil) { term, global in
                try await persist(term, global: global, origin: draft.origin)
            }
        }
    }

    private func termRow(_ entry: TermEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(entry.term.canonical).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
                Text(entry.global ? "全局" : "本录音").font(.system(size: 10)).foregroundStyle(.secondary)
                if entry.global, sessionID != nil, !effective.contains(where: { $0.id == entry.term.id }) {
                    Text("已被本录音覆盖").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("编辑") { editor = TermDraft(term: entry.term, global: entry.global, origin: entry) }
                Menu {
                    if !entry.global {
                        Button("保存到全局词库") { promote(entry) }
                    }
                    Button("删除", role: .destructive) { delete(entry) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20).accessibilityLabel("术语操作")
            }.controlSize(.small).disabled(mutating)
            if !entry.term.aliases.isEmpty { Text("别名：" + entry.term.aliases.joined(separator: "、")).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            if !entry.term.note.isEmpty { Text(entry.term.note).font(.system(size: 12)).textSelection(.enabled) }
            if entry.term.preserveOriginal { Text("翻译时保留原文").font(.system(size: 11)).foregroundStyle(.secondary) }
            else if !entry.term.translations.isEmpty {
                Text(entry.term.translations.keys.sorted().map { "\(SubtitleLanguage.name($0))：\(entry.term.translations[$0] ?? "")" }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            references(entry.term.references)
        }
    }

    private var conflictsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("选择同名术语的含义", systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
                VStack(alignment: .leading, spacing: 6) {
                    Text(conflict.name).font(.system(size: 12, weight: .medium))
                    Picker(sessionID == nil ? "全局使用" : "本录音使用", selection: Binding(
                        get: { conflict.selectedTermID ?? "" },
                        set: { choose($0, conflict: conflict) }
                    )) {
                        Text(sessionID != nil && conflict.scope == .global ? "沿用全局选择" : "待确认").tag("")
                        ForEach(effective.filter { conflict.termIDs.contains($0.id) }) { term in
                            Text(conflictLabel(term, conflict: conflict)).tag(term.id)
                        }
                    }.disabled(mutating)
                }
            }
        }.padding(12).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func references(_ values: [TranscriptCitation]) -> some View {
        if !values.isEmpty {
            DisclosureGroup("原文出处（\(values.count)）") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(values) { value in
                        MinutesCitationView(citation: value, onLocate: sessionID != nil && value.sessionID == sessionID ? { onLocate(value) } : nil)
                    }
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func conflictLabel(_ term: ConfirmedTerm, conflict: ConfirmedTermConflict) -> String {
        let context = term.note.isEmpty ? term.references.first?.text ?? term.aliases.joined(separator: "、") : term.note
        let detail = context.isEmpty ? "定义 \((conflict.termIDs.firstIndex(of: term.id) ?? 0) + 1)" : String(context.prefix(60))
        return term.canonical + " · " + detail
    }

    private func reload() {
        do {
            let global = try store.load(scope: .global).map { TermEntry(term: $0, global: true) }
            let local = try sessionID.map { id in try store.load(scope: .recording(id)).map { TermEntry(term: $0, global: false) } } ?? []
            let resolution = try store.effective(recordingID: sessionID)
            entries = local + global; effective = resolution.terms; conflicts = resolution.conflicts
            ignored = try sessionID.map { try store.ignoredSuggestions(recordingID: $0) } ?? []
        } catch { message = error.localizedDescription }
    }

    private func scope(global: Bool) -> ConfirmedTermScope {
        if !global, let sessionID { return .recording(sessionID) }
        return .global
    }

    private func persist(_ term: ConfirmedTerm, global: Bool, origin: TermEntry?) async throws {
        defer { reload(); onChange() }
        _ = try await store.upsert(term, scope: scope(global: global))
        if global, origin?.global == false, let sessionID {
            _ = try await store.delete(id: term.id, scope: .recording(sessionID))
        }
        message = nil
    }

    private func mutate(_ operation: @escaping () async throws -> Void) {
        mutating = true; message = nil
        Task {
            defer { mutating = false; reload() }
            do { try await operation(); onChange() }
            catch { message = error.localizedDescription }
        }
    }

    private func promote(_ entry: TermEntry) {
        mutate { try await persist(entry.term, global: true, origin: entry) }
    }
    private func delete(_ entry: TermEntry) {
        mutate { _ = try await store.delete(id: entry.term.id, scope: scope(global: entry.global)) }
    }
    private func choose(_ id: String, conflict: ConfirmedTermConflict) {
        mutate { _ = try await store.select(termID: id.isEmpty ? nil : id, for: conflict.name, scope: scope(global: sessionID == nil)) }
    }
    private func ignore(_ candidate: MinutesCandidateTerm) {
        guard let sessionID else { return }
        mutate { _ = try await store.ignoreSuggestion(id: candidate.id, recordingID: sessionID) }
    }
}

private struct TermEntry: Identifiable {
    let term: ConfirmedTerm
    let global: Bool
    var id: String { (global ? "global:" : "local:") + term.id }
}

private struct TermDraft: Identifiable {
    let id = UUID()
    var term: ConfirmedTerm
    var global: Bool
    var origin: TermEntry? = nil
}

private struct TermTranslationDraft: Identifiable {
    let id = UUID()
    var language: String
    var text: String
}

private struct TermEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let draft: TermDraft
    let allowsLocal: Bool
    let onSave: (ConfirmedTerm, Bool) async throws -> Void
    @State private var canonical: String
    @State private var aliases: String
    @State private var note: String
    @State private var global: Bool
    @State private var preserveOriginal: Bool
    @State private var translations: [TermTranslationDraft]
    @State private var busy = false
    @State private var message: String?

    init(draft: TermDraft, allowsLocal: Bool, onSave: @escaping (ConfirmedTerm, Bool) async throws -> Void) {
        self.draft = draft; self.allowsLocal = allowsLocal; self.onSave = onSave
        _canonical = State(initialValue: draft.term.canonical)
        _aliases = State(initialValue: draft.term.aliases.joined(separator: "\n"))
        _note = State(initialValue: draft.term.note)
        _global = State(initialValue: draft.global)
        _preserveOriginal = State(initialValue: draft.term.preserveOriginal)
        _translations = State(initialValue: draft.term.translations.keys.sorted().map { TermTranslationDraft(language: $0, text: draft.term.translations[$0] ?? "") })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.origin == nil ? "确认术语" : "编辑术语").font(.system(size: 20, weight: .semibold))
            Form {
                TextField("规范名称", text: $canonical)
                LabeledContent("别名（每行一个）") { TextEditor(text: $aliases).font(.system(size: 13)).frame(height: 60).border(.quaternary) }
                TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
                if allowsLocal { Toggle("保存到全局词库", isOn: $global) }
                Toggle("翻译时保留原文", isOn: $preserveOriginal)
                Section("目标语言译名") {
                    ForEach($translations) { $translation in
                        HStack {
                            TextField("语言代码，如 en", text: $translation.language).frame(width: 130)
                            TextField("译名", text: $translation.text)
                            Button { translations.removeAll { $0.id == translation.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("删除译名")
                        }
                    }
                    Button("添加译名") { translations.append(TermTranslationDraft(language: "", text: "")) }
                }
            }.formStyle(.grouped)
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).disabled(busy || canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 580, height: 520).interactiveDismissDisabled(busy)
    }

    private func save() {
        var values: [String: String] = [:]
        for row in translations {
            let language = row.language.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if language.isEmpty && text.isEmpty { continue }
            guard !language.isEmpty, !text.isEmpty else { message = "请同时填写目标语言和译名。"; return }
            guard values[language] == nil else { message = "同一目标语言只能填写一个译名。"; return }
            values[language] = text
        }
        var term = draft.term
        term.canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        term.aliases = aliases.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        term.note = note; term.translations = values; term.preserveOriginal = preserveOriginal
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { try await onSave(term, global); dismiss() }
            catch { message = error.localizedDescription }
        }
    }
}
