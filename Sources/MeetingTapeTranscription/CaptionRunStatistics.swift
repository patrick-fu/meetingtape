import Foundation

public struct CaptionRunStatistics: Codable, Sendable {
    public struct Distribution: Codable, Sendable {
        public let n: Int
        public let p50: Double?
        public let p95: Double?

        init(_ values: [Double]) {
            let sorted = values.sorted()
            n = sorted.count
            p50 = sorted.isEmpty ? nil : sorted[Int(ceil(Double(n) * 0.50)) - 1]
            p95 = sorted.isEmpty ? nil : sorted[Int(ceil(Double(n) * 0.95)) - 1]
        }
    }

    public struct Attempt: Codable, Sendable {
        public let jobID: String
        public let attemptID: String
        public let segmentID: String
        public let revision: Int
        public let versionID: String?
        public let targetLanguage: String
        public let provider: SubtitleTranslationProvider
        public let source: TranscriptSource
        public let final: Bool
        public let state: String
        public let queueSeconds: Double
        public let executionSeconds: Double?
        public let usage: [String: Int]?
        public let displaySeconds: Double?
        public let audioToDisplaySeconds: Double?
        public let throttleSeconds: Double?
        public let retryWaitSeconds: Double?
    }

    public struct Group: Codable, Sendable {
        public let provider: SubtitleTranslationProvider
        public let source: TranscriptSource
        public let final: Bool
        public let queueSeconds: Distribution
        public let executionSeconds: Distribution
        public let displaySeconds: Distribution
        public let audioToDisplaySeconds: Distribution
        public let throttleSeconds: Distribution
        public let retryWaitSeconds: Distribution
        public let failed: Int
        public let retries: Int
        public let cancelled: Int
        public let superseded: Int
        public let skipped: Int
        public let interrupted: Int
    }

    public let versionID: String?
    public let groups: [Group]
    public let attempts: [Attempt]
    public struct RecognitionGroup: Codable, Sendable {
        public let provider: LiveRecognitionProvider
        public let source: TranscriptSource
        public let firstDisplaySeconds: Distribution
        public let finalDisplaySeconds: Distribution
        public let receptionSeconds: Distribution
        public let presentationSeconds: Distribution
    }
    public let recognitionGroups: [RecognitionGroup]
    public let recognitionObservations: [CaptionRecognitionObservation]
    public let connections: [CaptionConnection]

    public init(archive: LiveCaptionArchive, versionID: String? = nil) {
        self.versionID = versionID
        recognitionObservations = archive.recognitionObservations
        connections = archive.connections
        var recognition: [[CaptionRecognitionObservation]] = []
        for item in recognitionObservations {
            if let index = recognition.firstIndex(where: { $0[0].provider == item.provider && $0[0].source == item.source }) { recognition[index].append(item) }
            else { recognition.append([item]) }
        }
        recognitionGroups = recognition.map { group in
            let firstPaints = Dictionary(grouping: group, by: \.segmentID).values.compactMap { revisions in
                revisions.filter { $0.displayedUptime != nil }.min { $0.displayedUptime! < $1.displayedUptime! }
            }
            return RecognitionGroup(provider: group[0].provider, source: group[0].source,
                firstDisplaySeconds: Distribution(firstPaints.compactMap(\.displaySeconds)),
                finalDisplaySeconds: Distribution(group.filter(\.final).compactMap(\.displaySeconds)),
                receptionSeconds: Distribution(group.compactMap(\.receptionSeconds)),
                presentationSeconds: Distribution(group.compactMap(\.presentationSeconds)))
        }
        let jobs = archive.translationJobs.filter { $0.versionID == versionID }
        attempts = jobs.flatMap { job in
            job.attempts.map { attempt in
                let original = archive.recognitionObservations.last { $0.segmentID == job.segmentID && $0.revision == job.revision && $0.producerID == attempt.producerID }
                let displayed = attempt.displayedUptime.flatMap { shown in attempt.receivedUptime.flatMap { shown >= $0 ? shown - $0 : nil } }
                let endToEnd = attempt.displayedUptime.flatMap { shown in original?.audioReadUptime.flatMap { shown >= $0 ? shown - $0 : nil } }
                return Attempt(jobID: job.id, attemptID: attempt.id, segmentID: job.segmentID,
                        revision: job.revision, versionID: job.versionID, targetLanguage: job.targetLanguage,
                        provider: job.provider, source: job.source, final: job.final, state: attempt.state,
                        queueSeconds: attempt.queueSeconds, executionSeconds: attempt.executionSeconds, usage: attempt.usage,
                        displaySeconds: displayed, audioToDisplaySeconds: endToEnd,
                        throttleSeconds: attempt.throttleSeconds, retryWaitSeconds: attempt.retryWaitSeconds)
            }
        }
        var grouped: [[CaptionTranslationJob]] = []
        for job in jobs {
            if let index = grouped.firstIndex(where: { $0[0].provider == job.provider && $0[0].source == job.source && $0[0].final == job.final }) {
                grouped[index].append(job)
            } else {
                grouped.append([job])
            }
        }
        let recordedAttempts = attempts
        groups = grouped.map { group in
            let successful = group.flatMap(\.attempts).filter { $0.state == "succeeded" }
            return Group(provider: group[0].provider, source: group[0].source, final: group[0].final,
                         queueSeconds: Distribution(successful.map(\.queueSeconds)),
                         executionSeconds: Distribution(successful.compactMap(\.executionSeconds)),
                         displaySeconds: Distribution(recordedAttempts.filter { $0.provider == group[0].provider && $0.source == group[0].source && $0.final == group[0].final && $0.state == "succeeded" }.compactMap(\.displaySeconds)),
                         audioToDisplaySeconds: Distribution(recordedAttempts.filter { $0.provider == group[0].provider && $0.source == group[0].source && $0.final == group[0].final && $0.state == "succeeded" }.compactMap(\.audioToDisplaySeconds)),
                         throttleSeconds: Distribution(successful.compactMap(\.throttleSeconds)),
                         retryWaitSeconds: Distribution(successful.compactMap(\.retryWaitSeconds)),
                         failed: group.flatMap(\.attempts).filter { $0.state == "failed" }.count,
                         retries: group.reduce(0) { $0 + max(0, $1.attempts.count - 1) },
                         cancelled: group.flatMap(\.attempts).filter { $0.state == "cancelled" }.count,
                         superseded: group.filter { $0.state == .superseded }.count,
                         skipped: group.filter { $0.state == .superseded && $0.attempts.isEmpty }.count,
                         interrupted: group.filter { $0.state == .interrupted }.count)
        }
    }

    public func markdown() -> String {
        var lines = ["| 阶段 / 模型 / 音源 | 指标 | n | p50 | p95 |", "| --- | --- | --- | --- | --- |"]
        func row(_ title: String, _ label: String, _ distribution: Distribution) -> String {
            "| \(title) | \(label) | \(distribution.n) | \(Self.seconds(distribution.p50)) | \(Self.seconds(distribution.p95)) |"
        }
        for group in recognitionGroups {
            let title = "识别 / \(group.provider.name) / \(group.source.name)"
            lines += [row(title, "首批字幕绘制", group.firstDisplaySeconds), row(title, "定稿绘制", group.finalDisplaySeconds), row(title, "客户端取得音频至识别结果", group.receptionSeconds), row(title, "识别结果至绘制", group.presentationSeconds)]
        }
        var counts: [String] = []
        for group in groups {
            let title = "翻译 / \(group.provider.name) / \(group.source.name) / \(group.final ? "定稿" : "草稿")"
            lines += [row(title, "排队", group.queueSeconds), row(title, "草稿频控等待", group.throttleSeconds), row(title, "重试就绪等待", group.retryWaitSeconds), row(title, "客户端调用", group.executionSeconds), row(title, "客户端取得音频至译文绘制", group.audioToDisplaySeconds), row(title, "译文结果至绘制", group.displaySeconds)]
            counts += ["- \(title)：失败 \(group.failed)，重试 \(group.retries)，取消 \(group.cancelled)，被替代 \(group.superseded)，未发出跳过 \(group.skipped)，中断 \(group.interrupted)。"]
        }
        lines += [""] + counts + [""]
        for connection in connections {
            lines += ["- \(connection.modelName) / \(connection.source.name)：CPU \(Self.seconds(connection.cpuSeconds))；峰值 RSS \(connection.peakResidentBytes.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "未知")；范围 \(connection.resourceScope ?? "未知")。"]
        }
        lines += ["", "音频起点是客户端实际取得对应音频块的时钟；绘制为 AppKit 绘制回执，未观测到的路径标为未知。连接存续时间不作为识别延迟。CLI 不产生绘制回执。", "", "<details>", "<summary>逐请求明细</summary>", "", "| 请求 | 音源 / 修订 | 状态 | 排队 | 客户端调用 | 结果至绘制 | 用量 |", "| --- | --- | --- | --- | --- | --- | --- |"]
        for item in attempts {
            let usage = item.usage.flatMap { $0.isEmpty ? nil : $0.keys.sorted().map { "\($0)=\(item.usage![$0]!)" }.joined(separator: ", ") } ?? "未知"
            lines += ["| \(item.attemptID) | \(item.source.name) / \(item.revision) | \(item.state) | \(Self.seconds(item.queueSeconds)) | \(Self.seconds(item.executionSeconds)) | \(Self.seconds(item.displaySeconds)) | \(usage) |"]
        }
        lines += ["", "</details>", ""]
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f s", $0) } ?? "未知" }
}
