import AppKit
import Combine
import Foundation
import MeetingTapeTranscription

@MainActor
final class TranscriptionModel: ObservableObject {
    @Published var inventory: TranscriptionInventory?
    @Published var tasks: [TranscriptionTask] = []
    @Published var results: [String: [TranscriptModel: TranscriptResult]] = [:]
    @Published var message: String?
    @Published var busy = false
    @Published var existingModels: [String: LocalInstallation] = [:]
    private let client = RecordingClient()
    private var polling = false
    private var timer: Task<Void, Never>?
    private var existingRoot: URL?

    func launch() {
        if let data = UserDefaults.standard.data(forKey: "transcriptionModelBookmark") {
            var stale = false
            do {
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                _ = url.startAccessingSecurityScopedResource(); existingRoot = url
                if stale { UserDefaults.standard.set(try url.bookmarkData(options: .withSecurityScope), forKey: "transcriptionModelBookmark") }
            } catch { message = "已有模型目录访问凭据需要刷新，请在设置中重新选择目录。" }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        guard !polling, !busy else { return }
        polling = true; defer { polling = false }
        do {
            let data = try await client.data(["transcribe", "list"])
            tasks = try JSONDecoder().decode([TranscriptionTask].self, from: data)
            var values: [String: [TranscriptModel: TranscriptResult]] = [:]
            let snapshots = tasks
            values = await Task.detached {
                var result: [String: [TranscriptModel: TranscriptResult]] = [:]
                guard let store = try? TranscriptionStore() else { return result }
                for task in snapshots { for run in task.runs {
                    if let transcript = try? store.result(task.id, model: run.model) { result[task.id, default: [:]][run.model] = transcript }
                } }
                return result
            }.value
            results = values
            inventory = try JSONDecoder().decode(TranscriptionInventory.self, from: await client.data(["transcribe", "models"]))
        } catch { message = error.localizedDescription }
    }

    func task(for path: String) -> TranscriptionTask? { tasks.first { URL(fileURLWithPath: $0.inputPath).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path } }

    func start(_ item: RecordingItem, models: [TranscriptModel]) {
        var arguments = ["transcribe", "start", item.url.path, "--models", models.map(\.rawValue).joined(separator: ",")]
        if models.contains(.doubao) { arguments.append("--allow-cloud") }
        perform(arguments)
    }
    func retry(_ task: TranscriptionTask, model: TranscriptModel, source: TranscriptSource) { perform(["transcribe", "retry", task.id, model.rawValue, "--source", source.rawValue]) }
    func install(_ model: TranscriptModel, profile: String, reuse: Bool) {
        perform(["transcribe", "install", model.rawValue, "--profile", profile] + (reuse ? ["--reuse"] : []) + (reuse ? existingRoot.map { ["--reuse-root", $0.path] } ?? [] : []))
    }
    func discoverExisting() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择已有模型的运行时文件夹（包含 active.json）"
        panel.prompt = "使用此目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        existingRoot?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource(); existingRoot = url
        do { UserDefaults.standard.set(try url.bookmarkData(options: .withSecurityScope), forKey: "transcriptionModelBookmark") }
        catch {
            UserDefaults.standard.removeObject(forKey: "transcriptionModelBookmark")
            message = "本次可使用所选目录，重开应用后需要重新选择。"
        }
        Task {
            do {
                let data = try await client.data(["transcribe", "models", "--existing-root", url.path])
                existingModels = try JSONDecoder().decode(TranscriptionInventory.self, from: data).existingInstallations
                if existingModels.isEmpty { message = "未发现已有本地转写模型，可选择一键安装。" }
            } catch { message = error.localizedDescription }
        }
    }
    func save(_ settings: TranscriptionSettings) { perform(["transcribe", "settings", "--save-stdin"], input: try? JSONEncoder().encode(settings), success: "转写偏好已保存") }
    func credentials(_ credential: DoubaoCredential) { perform(["transcribe", "credentials", "save-stdin"], input: try? JSONEncoder().encode(credential), success: "凭据已保存到钥匙串") }
    func testConnection() { perform(["transcribe", "credentials", "test"], success: "豆包已接受测试请求") }
    func removeCredentials() { perform(["transcribe", "credentials", "remove"], success: "已移除钥匙串中的豆包凭据") }

    private func perform(_ arguments: [String], input: Data? = nil, success: String? = nil) {
        guard !busy else { return }
        busy = true; message = nil
        Task {
            do { _ = try await client.data(arguments, input: input); message = success }
            catch { message = error.localizedDescription }
            busy = false; await refresh()
        }
    }
}
