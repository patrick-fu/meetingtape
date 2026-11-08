import CryptoKit
import Foundation
import Security

public enum TextModelLocation: String, Codable, CaseIterable, Sendable, Identifiable {
    case local, cloud
    public var id: Self { self }
    public var name: String { self == .local ? "本地模型" : "云端模型（BYOK）" }
}

public struct TextModelConnection: Codable, Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public init(baseURL: String, model: String = "") { self.baseURL = baseURL; self.model = model }

    public func endpoint(location: TextModelLocation) throws -> URL {
        guard let url = URL(string: baseURL), let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw TranscriptionFailure("请输入有效的模型 API 地址。") }
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        guard location == .local ? loopback && ["http", "https"].contains(url.scheme) : url.scheme == "https" else { throw TranscriptionFailure(location == .local ? "本地模型使用本机地址。" : "云端模型使用 HTTPS 地址。") }
        return url
    }
}

public struct TextModelSettings: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var provider: TextModelLocation = .local
    public var local = TextModelConnection(baseURL: "http://127.0.0.1:11434/v1")
    public var cloud = TextModelConnection(baseURL: "https://ark.cn-beijing.volces.com/api/v3")
    public var automatic = true
    public var automaticSince: Date?
    public var language = "zh-Hans"
    public init() {}
    public var connection: TextModelConnection { provider == .local ? local : cloud }
    public var configured: Bool { !connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public struct TextModelConfiguration: Sendable {
    private let directory: URL
    public init(directory: URL? = nil) {
        let library = ProcessInfo.processInfo.environment["MEETINGTAPE_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape")
        self.directory = directory ?? library.appendingPathComponent("TextModels")
    }
    public func load() throws -> TextModelSettings {
        let file = directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return TextModelSettings() }
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 65536 else { throw TranscriptionFailure("纪要模型设置过大。") }
        let settings = try JSONDecoder().decode(TextModelSettings.self, from: Data(contentsOf: file))
        try validate(settings)
        return settings
    }
    public func save(_ settings: TextModelSettings) throws {
        try validate(settings)
        try TranscriptionStore.directory(directory)
        let lock = try TranscriptionLock(directory.appendingPathComponent("settings.lock"), wait: true)
        defer { withExtendedLifetime(lock) {} }
        let prior = try load()
        var settings = settings
        if settings.automatic, settings.configured {
            settings.automaticSince = prior.automatic && prior.configured ? prior.automaticSince ?? Date() : Date()
        } else { settings.automaticSince = nil }
        let data = try JSONEncoder().encode(settings)
        let file = directory.appendingPathComponent("settings.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func validate(_ settings: TextModelSettings) throws {
        guard settings.schemaVersion == 1, ["zh-Hans", "en"].contains(settings.language),
              settings.local.model.utf8.count <= 1024, settings.cloud.model.utf8.count <= 1024,
              settings.local.baseURL.utf8.count <= 4096, settings.cloud.baseURL.utf8.count <= 4096 else { throw TranscriptionFailure("纪要模型设置无效，已有设置已保留。") }
        _ = try settings.local.endpoint(location: .local)
        _ = try settings.cloud.endpoint(location: .cloud)
    }
}

public enum TextModelCredentials {
    private static func query(_ connection: TextModelConnection) throws -> [String: Any] {
        let endpoint = try connection.endpoint(location: .cloud)
        let account = SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.paaatrickfu.meetingtape.text-models", kSecAttrAccount as String: account]
    }
    public static func save(_ key: String, connection: TextModelConnection) throws {
        guard !key.isEmpty, key.utf8.count <= 16384, !key.contains("\n"), !key.contains("\r") else { throw TranscriptionFailure("请输入有效的 API Key。") }
        let query = try query(connection), data = Data(key.utf8)
        var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        let status = updated == errSecItemNotFound ? SecItemAdd(item as CFDictionary, nil) : updated
        guard status == errSecSuccess else { throw TranscriptionFailure("无法保存纪要 API Key（\(status)）。") }
    }
    public static func load(connection: TextModelConnection) throws -> String {
        var query = try query(connection); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw TranscriptionFailure(status == errSecItemNotFound ? "请在设置中配置此地址的纪要 API Key。" : "无法读取纪要 API Key（\(status)）。")
        }
        return key
    }
    public static func remove(connection: TextModelConnection) throws {
        let status = SecItemDelete(try query(connection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TranscriptionFailure("无法移除纪要 API Key（\(status)）。") }
    }
}

private final class TextModelRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum TextModelClient {
    public static func generate(system: String, user: String, settings: TextModelSettings, key: String? = nil, maxTokens: Int = 4096) async throws -> MinutesGenerationOutput {
        guard settings.configured else { throw TranscriptionFailure("请先在设置中选择纪要模型。") }
        let connection = settings.connection
        let base = try connection.endpoint(location: settings.provider)
        let endpoint = base.path.hasSuffix("/chat/completions") ? base : base.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if settings.provider == .cloud { request.setValue("Bearer " + (try key ?? TextModelCredentials.load(connection: connection)), forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": connection.model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]], "stream": false, "temperature": 0.2, "max_tokens": maxTokens])
        guard (request.httpBody?.count ?? 0) <= 10 * 1_048_576 else { throw TranscriptionFailure("纪要输入超过单次请求上限。") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: TextModelRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let began = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TranscriptionFailure("纪要模型未返回有效响应。") }
        guard response.statusCode == 200 else { throw TranscriptionFailure("纪要模型请求失败（HTTP \(response.statusCode)），请检查连接、模型与权限。") }
        guard data.count <= 4 * 1_048_576, let payload = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any], let content = message["content"] as? String, !content.isEmpty else { throw TranscriptionFailure("纪要模型未返回正文。") }
        guard choice["finish_reason"] as? String != "length" else { throw TranscriptionFailure("纪要生成达到模型输出上限，请调整模型后重新生成。") }
        let usage = (payload["usage"] as? [String: Int])?.filter { ["prompt_tokens", "completion_tokens", "total_tokens"].contains($0.key) && $0.value >= 0 }
        return MinutesGenerationOutput(content: content, usage: usage, elapsedSeconds: began.duration(to: .now).secondsValue)
    }
}
