import AVFoundation
import CryptoKit
import Foundation

public struct TranscriptionInventory: Codable, Sendable {
    public var settings: TranscriptionSettings
    public var memoryGiB: Int
    public var recommendedProfile: String
    public var localSupported: Bool
    public var credentialConfigured: Bool
    public var existingInstallations: [String: LocalInstallation]
    public var installations: [ModelInstallationStatus]
    public var automaticError: String?
}

public enum LocalModels {
    public static func inventory(includeExisting: Bool = false) throws -> TranscriptionInventory {
        let store = try TranscriptionStore()
        let memory = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        var statuses = TranscriptModel.allCases.filter(\.local).compactMap { try? store.read(store.root.appendingPathComponent("install-\($0.rawValue).json")) as ModelInstallationStatus }
        if let lock = try? TranscriptionLock(store.root.appendingPathComponent("install.lock")) {
            defer { withExtendedLifetime(lock) {} }
            for index in statuses.indices where ["installing", "validating"].contains(statuses[index].state) {
                let path = store.root.appendingPathComponent("install-\(statuses[index].model.rawValue).json")
                let changed = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if Date().timeIntervalSince(changed) > 3 {
                    statuses[index].state = "failed"; statuses[index].message = "安装进程已中断，可以重新安装。"; statuses[index].processID = nil
                    try store.write(statuses[index], to: path)
                }
            }
        }
        let error = (try? store.read(store.root.appendingPathComponent("automatic-error.json")) as [String: String])?["message"]
        #if arch(arm64)
        let supported = memory >= 16
        #else
        let supported = false
        #endif
        return TranscriptionInventory(settings: try store.settings(), memoryGiB: memory, recommendedProfile: memory >= 32 ? "standard" : "low-memory",
            localSupported: supported, credentialConfigured: TranscriptionCredentials.configured(), existingInstallations: includeExisting ? existing() : [:], installations: statuses, automaticError: error)
    }

    public static func existing(root selectedRoot: URL? = nil) -> [String: LocalInstallation] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storagePath = support.appendingPathComponent("audio-transcription/storage.json")
        let storage = selectedRoot == nil ? (try? JSONSerialization.jsonObject(with: Data(contentsOf: storagePath))) as? [String: Any] : nil
        let root = selectedRoot ?? (storage?["app_root"] as? String).map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("audio-transcription")
        guard let active = (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("active.json")))) as? [String: Any],
              let python = active["python"] as? String, let profile = active["profile"] as? String,
              let models = active["models"] as? [String: [String: Any]] else { return [:] }
        var values: [String: LocalInstallation] = [:]
        for family in ["qwen", "moss"] {
            guard let model = models[family], let path = model["path"] as? String, let revision = model["revision"] as? String,
                  let repository = model["repo"] as? String else { continue }
            values[family] = LocalInstallation(family: family, profile: profile, python: python, model: path, revision: revision,
                repository: repository, runtimeVersion: active["runtime_version"] as? String ?? "external", ready: false)
        }
        return values
    }

    public static func launch(model: TranscriptModel, profile: String, reuse: Bool, reuseRoot: String? = nil) throws {
        guard model.local, ["low-memory", "standard"].contains(profile) else { throw TranscriptionFailure("无效的本地模型配置。") }
        let store = try TranscriptionStore()
        let guardLock = try TranscriptionLock(store.root.appendingPathComponent("install-launch.lock"), wait: true)
        defer { withExtendedLifetime(guardLock) {} }
        if let lock = try? TranscriptionLock(store.root.appendingPathComponent("install.lock")) { withExtendedLifetime(lock) {} }
        else { throw TranscriptionFailure("另一个模型正在安装，请稍后。") }
        guard let executable = Bundle.main.executableURL else { throw TranscriptionFailure("无法找到转写组件。") }
        let process = Process(); process.executableURL = executable
        process.arguments = ["__install", model.rawValue, profile, reuse ? "reuse" : "download"]
        if let reuseRoot { process.arguments?.append(reuseRoot) }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        try store.write(ModelInstallationStatus(model: model, profile: profile, state: "installing", message: reuse ? "正在验证已有模型" : "正在准备运行时与模型", processID: process.processIdentifier), to: store.root.appendingPathComponent("install-\(model.rawValue).json"))
    }

    public static func install(model: TranscriptModel, profile: String, reuse: Bool, reuseRoot: String? = nil) throws {
        let store = try TranscriptionStore()
        let lock = try TranscriptionLock(store.root.appendingPathComponent("install.lock"))
        defer { withExtendedLifetime(lock) {} }
        let status = store.root.appendingPathComponent("install-\(model.rawValue).json")
        do {
            guard ProcessInfo.processInfo.physicalMemory >= 16 * 1_073_741_824 else { throw TranscriptionFailure("当前版本的本地模型需要至少 16 GB 内存，请使用豆包。") }
            var installation: LocalInstallation
            if reuse {
                guard let value = existing(root: reuseRoot.map { URL(fileURLWithPath: $0) })[model.rawValue] else { throw TranscriptionFailure("没有找到可复用模型。") }
                installation = value
            } else {
                let capacity = try store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard capacity >= (profile == "standard" ? 12 : 10) * 1_073_741_824 else { throw TranscriptionFailure("可用磁盘空间不足，请至少保留 \(profile == "standard" ? 12 : 10) GB 后安装。") }
                let resources = try TranscriptionResources.directory()
                let uv = try prepareUV(store)
                let destination = store.root.appendingPathComponent("local")
                try TranscriptionStore.directory(destination)
                let descriptor = destination.appendingPathComponent("\(model.rawValue)-\(profile).json")
                let output = try TranscriptionProcess.run(uv, ["run", "--no-project", "--python", "3.11.14", resources.appendingPathComponent("bootstrap.py").path,
                    "--model-type", model.rawValue, "--profile", profile, "--root", destination.path, "--uv", uv.path, "--output", descriptor.path], environment: TranscriptionProcess.environment(offline: false), timeout: 3600)
                guard output.status == 0 else { throw TranscriptionFailure("安装失败：" + String(decoding: output.errors.suffix(1800), as: UTF8.self)) }
                installation = try store.read(descriptor)
            }
            try store.write(ModelInstallationStatus(model: model, profile: installation.profile, state: "validating", message: "等待空闲后验证模型", processID: getpid()), to: status)
            let smoke = store.root.appendingPathComponent("smoke-\(model.rawValue).wav")
            let raw = store.root.appendingPathComponent("smoke-\(model.rawValue).json")
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000) else { throw TranscriptionFailure("无法生成模型验证音频。") }
            buffer.frameLength = 16000
            if let samples = buffer.int16ChannelData?[0] { samples.initialize(repeating: 0, count: 16000) }
            do { let file = try AVAudioFile(forWriting: smoke, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true); try file.write(from: buffer) }
            var validated = false
            repeat {
                let outcome: Bool? = try TranscriptionProcess.local { lease in
                    let output = try TranscriptionProcess.run(URL(fileURLWithPath: installation.python), [try TranscriptionResources.directory().appendingPathComponent("local_runner.py").path,
                        "--model-type", model.rawValue, "--model", installation.model, "--audio", smoke.path, "--output", raw.path], environment: TranscriptionProcess.environment(offline: true), local: true, lease: lease, timeout: 180)
                    if output.yielded { return false }
                    guard output.status == 0, let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: raw)) as? [String: Any], payload["segments"] is [Any] else {
                        throw TranscriptionFailure("模型验证失败：" + String(decoding: output.errors.suffix(1400), as: UTF8.self))
                    }
                    return true
                }
                validated = outcome == true
                if !validated { Thread.sleep(forTimeInterval: 0.5) }
            } while !validated
            installation.ready = true
            try store.activate(installation)
            try store.write(ModelInstallationStatus(model: model, profile: installation.profile, state: "ready", message: "已验证，可离线使用", processID: nil), to: status)
            try? FileManager.default.removeItem(at: smoke); try? FileManager.default.removeItem(at: raw)
        } catch {
            try? store.write(ModelInstallationStatus(model: model, profile: profile, state: "failed", message: error.localizedDescription, processID: nil), to: status)
            throw error
        }
    }

    private static func prepareUV(_ store: TranscriptionStore) throws -> URL {
        for path in ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv").path] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let tools = store.root.appendingPathComponent("tools")
        try TranscriptionStore.directory(tools)
        let executable = tools.appendingPathComponent("uv-aarch64-apple-darwin/uv")
        if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        let archive = tools.appendingPathComponent("uv.tar.gz")
        let output = try TranscriptionProcess.run(URL(fileURLWithPath: "/usr/bin/curl"), ["--fail", "--location", "--max-time", "180", "https://github.com/astral-sh/uv/releases/download/0.13.5/uv-aarch64-apple-darwin.tar.gz", "--output", archive.path])
        guard output.status == 0, try TranscriptionStore.fingerprint(archive) == "743f85035a1996ecb350659e01cd9faea9709829be09b1b4b03c73eaf3c9cd73" else { throw TranscriptionFailure("下载工具未通过完整性校验。") }
        let extracted = try TranscriptionProcess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", tools.path])
        guard extracted.status == 0, FileManager.default.isExecutableFile(atPath: executable.path) else { throw TranscriptionFailure("无法准备本地安装工具。") }
        return executable
    }
}
