import Foundation
import MeetingTapeCore

public actor LiveCaptionSession {
    private let snapshot: SessionSnapshot
    private let origin: Double
    private let store: LiveCaptionStore
    private let credential: DoubaoCredential?
    private let options: SubtitleOptions
    private let translator: CaptionTranslate
    private var services: [TranscriptSource: LiveSourceCaptionSession] = [:]
    private var tasks: [TranscriptSource: Task<LiveCaptionArchive, Never>] = [:]
    private var completed: SessionSnapshot?
    private var cancelled = false
    private var started = false

    public init(snapshot: SessionSnapshot, startAt: Double = 0, store: LiveCaptionStore = LiveCaptionStore(), credential: DoubaoCredential? = nil,
                options: SubtitleOptions = SubtitleOptions(), translator: @escaping CaptionTranslate = { try await TextTranslation.translate($0, target: $1, provider: $2) }) {
        self.snapshot = snapshot; origin = startAt; self.store = store; self.credential = credential
        self.options = options; self.translator = translator
    }

    public func finish(_ value: SessionSnapshot) async {
        guard value.sessionID == snapshot.sessionID else { return }
        completed = value
        for service in services.values { await service.finish(value) }
    }

    public func cancel() async {
        cancelled = true
        for task in tasks.values { task.cancel() }
        for service in services.values { await service.cancel() }
    }

    public func run(update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async -> LiveCaptionArchive {
        var document = LiveCaptionArchive(sessionID: snapshot.sessionID)
        guard !started else { return (try? await store.load(snapshot.sessionID)) ?? document }
        started = true
        do {
            guard origin.isFinite, origin >= 0, origin <= 86400 else { throw TranscriptionFailure("实时字幕的起始时间无效。") }
            if let existing = try await store.load(snapshot.sessionID) { document = existing }
        } catch {
            document.partial = true; document.message = "无法读取已有字幕，原文件已保留：\(error.localizedDescription)"
            await update(document)
            return document
        }
        let mode = snapshot.recognitionMode ?? .merged
        guard options.transcription || options.translation, !cancelled else { return document }
        for source in mode.sources { await start(source, at: origin, update: update) }
        return await withTaskCancellationHandler {
            while !tasks.isEmpty {
                if Task.isCancelled {
                    await cancel()
                    for pending in Array(tasks.values) { _ = await pending.value }
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return (try? await store.load(snapshot.sessionID)) ?? document
        } onCancel: { Task { await self.cancel() } }
    }

    private var update: (@Sendable (LiveCaptionArchive) async -> Void)?

    public func retryFailed(at time: Double) async -> Bool {
        guard !cancelled, completed == nil, time.isFinite, time >= 0,
              let update, let archive = try? await store.load(snapshot.sessionID) else { return false }
        var resumed = false
        for source in (snapshot.recognitionMode ?? .merged).sources {
            guard tasks[source] == nil, archive.connections.last(where: { $0.source == source })?.state == "failed" else { continue }
            await start(source, at: time, update: update)
            resumed = true
        }
        return resumed
    }

    private func start(_ source: TranscriptSource, at origin: Double, update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async {
        self.update = update
        let service = LiveSourceCaptionSession(snapshot: snapshot, startAt: origin, source: source, mode: snapshot.recognitionMode ?? .merged, options: options, translator: translator, store: store, credential: credential)
        services[source] = service
        if let completed { await service.finish(completed) }
        if cancelled { await service.cancel() }
        tasks[source] = Task {
            let result = await service.run(update: update)
            tasks.removeValue(forKey: source)
            return result
        }
    }

}

private actor LiveSourceCaptionSession {
    private let snapshot: SessionSnapshot
    private let origin: Double
    private let store: LiveCaptionStore
    private let credential: DoubaoCredential?
    private var socket: URLSessionWebSocketTask?
    private var completed: SessionSnapshot?
    private var cancelled = false
    private var started = false
    private var serverFinal = false
    private var receiveFailure: String?
    private var document: LiveCaptionArchive
    private let source: TranscriptSource
    private let mode: RecognitionMode
    private let options: SubtitleOptions
    private let translator: CaptionTranslate
    private var connection: CaptionConnection
    private var drafts: CaptionDraftBuffer
    private var translations: [String: Task<Void, Never>] = [:]
    private var elapsedStart = 0.0

    init(snapshot: SessionSnapshot, startAt: Double, source: TranscriptSource, mode: RecognitionMode,
         options: SubtitleOptions, translator: @escaping CaptionTranslate, store: LiveCaptionStore, credential: DoubaoCredential?) {
        self.snapshot = snapshot; origin = startAt; self.source = source; self.mode = mode
        self.options = options; self.translator = translator; self.store = store; self.credential = credential
        connection = CaptionConnection(id: UUID().uuidString.lowercased(), source: source, start: startAt, end: startAt, complete: false, state: "connecting")
        document = LiveCaptionArchive(sessionID: snapshot.sessionID)
        drafts = CaptionDraftBuffer(connectionID: connection.id, source: source, options: options)
    }

    public func finish(_ value: SessionSnapshot) {
        guard value.sessionID == snapshot.sessionID else { return }
        completed = value
    }

    public func cancel() {
        cancelled = true
        for task in translations.values { task.cancel() }
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    public func run(update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async -> LiveCaptionArchive {
        guard !started else { return document }
        started = true
        return await withTaskCancellationHandler {
            await execute(update: update)
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func execute(update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async -> LiveCaptionArchive {
        do {
            guard origin.isFinite, origin >= 0, origin <= 86400 else { throw TranscriptionFailure("实时字幕的起始时间无效。") }
            _ = try await store.load(snapshot.sessionID)
        } catch {
            document.complete = false; document.partial = true
            document.message = "无法读取已有字幕，原文件已保留：\(error.localizedDescription)"
            await update(document)
            return document
        }
        do {
            if cancelled { throw CancellationError() }
            document.complete = false; document.partial = false; document.message = nil
            elapsedStart = ProcessInfo.processInfo.systemUptime
            _ = try await persist()
            let key = try credential ?? TranscriptionCredentials.load()
            var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
            request.timeoutInterval = 15
            request.setValue("volc.seedasr.sauc.duration", forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(connection.id, forHTTPHeaderField: "X-Api-Request-Id")
            if !key.apiKey.isEmpty { request.setValue(key.apiKey, forHTTPHeaderField: "X-Api-Key") }
            else {
                request.setValue(key.appID, forHTTPHeaderField: "X-Api-App-Key")
                request.setValue(key.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 86400
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let connection = session.webSocketTask(with: request)
            connection.maximumMessageSize = 8 * 1_048_576
            socket = connection; connection.resume()
            let payload: [String: Any] = ["user": ["uid": "meetingtape"],
                "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
                "request": ["model_name": "bigmodel", "enable_punc": true, "enable_ddc": false,
                            "enable_nonstream": true, "show_utterances": true, "result_type": "full"]]
            try await send(DoubaoLiveCodec.packet(try JSONSerialization.data(withJSONObject: payload), audio: false), on: connection)
            let receiver = Task { await self.receive(connection, update: update) }
            defer { receiver.cancel(); connection.cancel(with: .normalClosure, reason: nil); socket = nil }
            let reader = LiveAudioReader(snapshot: snapshot, startFrame: Int64((origin * 48000).rounded()), source: source)
            let converter = try LivePCMConverter()
            var missingSince: Date?
            while true {
                try Task.checkCancellation()
                if cancelled { throw CancellationError() }
                if let receiveFailure { throw TranscriptionFailure(receiveFailure) }
                if serverFinal { throw TranscriptionFailure("实时字幕会话已结束，录音继续。请重新连接字幕。") }
                let samples: [Float]?
                if let completed {
                    samples = try reader.readFinal(completed)
                    if samples == nil {
                        if completed.state != .completed { document.partial = true }
                        break
                    }
                } else {
                    samples = try reader.readCommitted()
                    if samples == nil && reader.sealed {
                        if reader.state == .failed { document.partial = true }
                        break
                    }
                }
                if let samples {
                    missingSince = nil
                    let bytes = try converter.convert(samples)
                    if !bytes.isEmpty {
                        try await send(DoubaoLiveCodec.packet(bytes, audio: true), on: connection)
                        self.connection.end = Double(reader.cursor) / 48000
                        self.connection.state = "running"
                    }
                } else {
                    if !reader.available {
                        if missingSince == nil { missingSince = Date() }
                        if Date().timeIntervalSince(missingSince!) > 15 { throw TranscriptionFailure("未取得录音尾部，已保留现有字幕。") }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let tail = try converter.convert([], final: true)
            try await send(DoubaoLiveCodec.packet(tail, audio: true, final: true), on: connection)
            let deadline = Task {
                try? await Task.sleep(for: .seconds(12))
                if !Task.isCancelled { connection.cancel(with: .goingAway, reason: nil) }
            }
            await receiver.value; deadline.cancel()
            guard serverFinal else { throw TranscriptionFailure(receiveFailure ?? "字幕尾句未完成，已保留现有文字。") }
            for pending in Array(translations.values) { await pending.value }
            document.complete = !document.partial && document.segments.allSatisfy(\.final)
            if !document.complete { document.message = "这份实时字幕包含未转写或未定稿的区间。" }
        } catch {
            document.complete = false; document.partial = true
            document.message = cancelled || error is CancellationError ? "实时字幕已结束，已保留当前文字。" : error.localizedDescription
        }
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        connection.complete = document.complete
        connection.state = cancelled ? "cancelled" : document.complete ? "completed" : "failed"
        connection.elapsedSeconds = elapsedStart > 0 ? max(0, ProcessInfo.processInfo.systemUptime - elapsedStart) : nil
        for task in translations.values { task.cancel() }
        drafts.discardOriginals()
        do {
            let saved = try await persist()
            await update(saved)
            return saved
        } catch {
            document.message = "实时字幕未保存：\(error.localizedDescription)"; document.complete = false
            await update(document)
            return document
        }
    }

    private func receive(_ connection: URLSessionWebSocketTask, update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async {
        do {
            while !Task.isCancelled && !cancelled {
                let value = try await connection.receive()
                let data: Data
                switch value {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: throw TranscriptionFailure("实时字幕响应类型不兼容。")
                }
                let frame = try DoubaoLiveCodec.decode(data, origin: origin)
                if frame.hasResult {
                    let pending = drafts.receive(frame.segments)
                    document.segments = drafts.segments
                    let present = Set(document.segments.map(\.id))
                    for (id, task) in translations where !present.contains(id) { task.cancel(); translations.removeValue(forKey: id) }
                    for raw in pending { schedule(raw, update: update) }
                    guard document.segments.count <= 20_000 else { throw TranscriptionFailure("实时字幕已达到单次文本上限，录音继续。") }
                }
                await update(try await persist())
                if frame.final { serverFinal = true; return }
            }
        } catch {
            if !cancelled && !Task.isCancelled {
                let status = (connection.response as? HTTPURLResponse)?.statusCode
                receiveFailure = status.map { $0 != 101 ? "豆包实时字幕连接失败（HTTP \($0)），请检查凭据与服务权限。" : error.localizedDescription } ?? "豆包实时字幕连接中断，录音继续。"
                connection.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func persist() async throws -> LiveCaptionArchive {
        try await store.updateConnection(snapshot.sessionID, mode: mode, connection: connection, segments: document.segments)
    }

    private func schedule(_ raw: LiveCaptionSegment, update: @escaping @Sendable (LiveCaptionArchive) async -> Void) {
        translations[raw.id]?.cancel()
        let options = self.options, translator = self.translator
        translations[raw.id] = Task {
            do {
                if !raw.final { try await Task.sleep(for: .milliseconds(450)) }
                try Task.checkCancellation()
                let translated = try await translator(raw.text, options.targetLanguage, options.provider)
                try Task.checkCancellation()
                await apply(translated, raw: raw, update: update)
            } catch {
                if !Task.isCancelled {
                    await apply(CaptionTranslation(targetLanguage: options.targetLanguage, state: .failed, provider: options.provider.rawValue), raw: raw, update: update)
                }
            }
        }
    }

    private func apply(_ value: CaptionTranslation, raw: LiveCaptionSegment, update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async {
        guard !cancelled, drafts.apply(value, id: raw.id, revision: raw.revision) else { return }
        document.segments = drafts.segments
        do { await update(try await persist()) }
        catch { receiveFailure = "字幕保存失败，已停止更新以保留原稿。" }
    }

    private func send(_ bytes: Data, on connection: URLSessionWebSocketTask) async throws {
        let deadline = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { connection.cancel(with: .goingAway, reason: nil) }
        }
        defer { deadline.cancel() }
        do { try await connection.send(.data(bytes)) }
        catch { throw TranscriptionFailure(receiveFailure ?? "实时字幕发送失败，录音继续。") }
    }
}
