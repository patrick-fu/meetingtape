import Foundation

enum Doubao {
    struct Response { let code: String; let logID: String?; let body: [String: Any] }

    static func request(_ action: String, id: String, credential: DoubaoCredential, body: [String: Any]) throws -> Response {
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/" + action)!)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("volc.seedasr.auc", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Request-Id")
        if action == "submit" { request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence") }
        if !credential.apiKey.isEmpty { request.setValue(credential.apiKey, forHTTPHeaderField: "X-Api-Key") }
        else {
            request.setValue(credential.appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(credential.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let result = HTTPResult()
        let ready = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            result.set(data: data, response: response, error: error); ready.signal()
        }
        task.resume(); ready.wait()
        if let error = result.error { throw TranscriptionFailure("豆包连接失败：\(error.localizedDescription)") }
        guard let response = result.response else { throw TranscriptionFailure("豆包未返回有效响应。") }
        let code = response.value(forHTTPHeaderField: "X-Api-Status-Code") ?? "HTTP \(response.statusCode)"
        let body = ((try? JSONSerialization.jsonObject(with: result.data ?? Data())) as? [String: Any]) ?? [:]
        return Response(code: code, logID: response.value(forHTTPHeaderField: "X-Tt-Logid"), body: body)
    }

    static func payload(_ audio: URL) throws -> [String: Any] {
        let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 512 * 1024 * 1024 else { throw TranscriptionFailure("豆包音频超过 512 MB，请拆分录音后再转写。") }
        return ["user": ["uid": "meetingtape"],
                "audio": ["data": try Data(contentsOf: audio).base64EncodedString(), "format": "wav", "rate": 16000, "bits": 16, "channel": 1],
                "request": ["model_name": "bigmodel", "show_utterances": true, "enable_punc": true, "enable_ddc": false, "enable_speaker_info": true, "ssd_version": "300"]]
    }

    static func parse(_ response: Response, duration: Double) throws -> TranscriptResult {
        if response.code == "20000003" { return TranscriptResult(model: .doubao, revision: "volc.seedasr.auc", segments: []) }
        guard response.code == "20000000", let result = response.body["result"] as? [String: Any] else {
            throw TranscriptionFailure("豆包转写失败（\(response.code)）。")
        }
        let raw = result["utterances"] as? [[String: Any]] ?? []
        var segments: [TranscriptSegment] = []
        for value in raw {
            guard let start = value["start_time"] as? Double, let end = value["end_time"] as? Double,
                  let text = value["text"] as? String, start.isFinite, end.isFinite, start >= 0, end >= start, start / 1000 <= duration else { continue }
            let additions = value["additions"] as? [String: Any]
            let speaker = additions?["speaker"].map { String(describing: $0) }
            segments.append(TranscriptSegment(id: segments.count, start: start / 1000, end: min(end / 1000, duration), text: text, speaker: speaker))
        }
        if segments.isEmpty, let text = result["text"] as? String, !text.isEmpty {
            segments = [TranscriptSegment(id: 0, start: 0, end: duration, text: text, precision: "chunk")]
        }
        return TranscriptResult(model: .doubao, revision: "volc.seedasr.auc", segments: segments.sorted { $0.start < $1.start })
    }
}

private final class HTTPResult: @unchecked Sendable {
    var data: Data?
    var response: HTTPURLResponse?
    var error: (any Error)?
    func set(data: Data?, response: URLResponse?, error: (any Error)?) { self.data = data; self.response = response as? HTTPURLResponse; self.error = error }
}
