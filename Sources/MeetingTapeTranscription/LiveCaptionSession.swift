import Foundation
import MeetingTapeCore

public actor LiveCaptionSession {
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
    private var previous: [LiveCaptionSegment] = []

    public init(snapshot: SessionSnapshot, startAt: Double = 0, store: LiveCaptionStore = LiveCaptionStore(), credential: DoubaoCredential? = nil) {
        self.snapshot = snapshot; self.origin = startAt; self.store = store; self.credential = credential
        document = LiveCaptionArchive(sessionID: snapshot.sessionID)
    }

    public func finish(_ value: SessionSnapshot) {
        guard value.sessionID == snapshot.sessionID else { return }
        completed = value
    }

    public func cancel() {
        cancelled = true
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
            if let saved = try await store.load(snapshot.sessionID) { document = saved; previous = saved.segments }
            document.complete = false; document.partial = document.partial || origin > 0; document.message = nil
            let key = try credential ?? TranscriptionCredentials.load()
            var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
            request.timeoutInterval = 15
            request.setValue("volc.seedasr.sauc.duration", forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
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
            let reader = LiveAudioReader(snapshot: snapshot, startFrame: Int64((origin * 48000).rounded()))
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
                    if !bytes.isEmpty { try await send(DoubaoLiveCodec.packet(bytes, audio: true), on: connection) }
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
            document.complete = !document.partial && document.segments.allSatisfy(\.final)
            if !document.complete { document.message = "这份实时字幕包含未转写或未定稿的区间。" }
        } catch {
            document.complete = false; document.partial = true
            document.message = cancelled || error is CancellationError ? "实时字幕已结束，已保留当前文字。" : error.localizedDescription
        }
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        do { try await store.save(document) }
        catch { document.message = "实时字幕未保存：\(error.localizedDescription)"; document.complete = false }
        await update(document)
        return document
    }

    private func receive(_ connection: URLSessionWebSocketTask, update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async {
        var saved = previous.filter(\.final)
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
                    document.segments = previous + frame.segments
                    guard document.segments.count <= 20_000 else { throw TranscriptionFailure("实时字幕已达到单次文本上限，录音继续。") }
                    let finalized = document.segments.filter(\.final)
                    if finalized != saved || frame.final {
                        try await store.save(document); saved = finalized
                    }
                }
                await update(document)
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
