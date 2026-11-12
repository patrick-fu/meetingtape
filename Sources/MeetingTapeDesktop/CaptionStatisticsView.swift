import Foundation
import MeetingTapeTranscription
import SwiftUI

struct CaptionStatisticsView: View {
    let archive: LiveCaptionArchive
    var versionID: String? = nil
    @State private var expanded = false
    @State private var attemptsExpanded = false

    private var statistics: CaptionRunStatistics { CaptionRunStatistics(archive: archive, versionID: versionID) }

    var body: some View {
        DisclosureGroup("运行明细", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if statistics.groups.isEmpty && archive.connections.isEmpty {
                    Text("暂无运行数据").foregroundStyle(.secondary)
                }
                ForEach(Array(statistics.recognitionGroups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("识别 · \(group.provider.name) · \(group.source.name)").fontWeight(.medium)
                        Text("首批字幕绘制 \(distribution(group.firstDisplaySeconds))")
                        Text("定稿绘制 \(distribution(group.finalDisplaySeconds))")
                        Text("取得音频至识别结果 \(distribution(group.receptionSeconds))")
                        Text("识别结果至绘制 \(distribution(group.presentationSeconds))")
                    }
                }
                ForEach(Array(statistics.groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("翻译 · \(group.provider.name) · \(group.source.name) · \(group.final ? "定稿" : "草稿")")
                            .fontWeight(.medium)
                        Text("排队 \(distribution(group.queueSeconds))")
                        Text("草稿频控等待 \(distribution(group.throttleSeconds))")
                        Text("重试就绪等待 \(distribution(group.retryWaitSeconds))")
                        Text("执行 \(distribution(group.executionSeconds))")
                        Text("取得音频至译文绘制 \(distribution(group.audioToDisplaySeconds))")
                        Text("译文结果至绘制 \(distribution(group.displaySeconds))")
                        Text("失败 \(group.failed) · 重试 \(group.retries) · 取消 \(group.cancelled) · 被替代 \(group.superseded) · 跳过 \(group.skipped) · 中断 \(group.interrupted)")
                    }
                }
                Text("音频以客户端取得对应音频块为起点；绘制回执来自 AppKit 绘制回调。未观测项显示未知。").foregroundStyle(.secondary)
                ForEach(Array(archive.connections.enumerated()), id: \.offset) { _, connection in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("识别 · \(connection.modelName) · \(connection.source.name)").fontWeight(.medium)
                        Text("资源范围：\(connection.resourceScope ?? "未知")")
                        Text("CPU 时间 \(seconds(connection.cpuSeconds)) · 峰值内存 \(bytes(connection.peakResidentBytes))")
                    }
                }
                if !statistics.attempts.isEmpty {
                    DisclosureGroup("逐请求明细", isExpanded: $attemptsExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(statistics.attempts.enumerated()), id: \.offset) { _, attempt in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(attempt.provider.name) · \(attempt.source.name) · \(attempt.final ? "定稿" : "草稿") · 修订 \(attempt.revision) · \(attempt.state)")
                                    Text("排队 \(seconds(attempt.queueSeconds)) · 执行 \(seconds(attempt.executionSeconds)) · 用量 \(usage(attempt.usage))")
                                    Text("片段 \(attempt.segmentID) · 目标 \(attempt.targetLanguage) · 任务 \(attempt.jobID) · 请求 \(attempt.attemptID)")
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }.padding(.top, 6)
                    }
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
        .font(.system(size: 12))
    }

    private func distribution(_ value: CaptionRunStatistics.Distribution) -> String {
        "n=\(value.n) · p50 \(seconds(value.p50)) · p95 \(seconds(value.p95))"
    }

    private func seconds(_ value: Double?) -> String {
        guard let value else { return "未知" }
        return String(format: "%.2f 秒", value)
    }

    private func bytes(_ value: Int64?) -> String {
        guard let value else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private func usage(_ value: [String: Int]?) -> String {
        guard let value else { return "未知" }
        guard !value.isEmpty else { return "未知" }
        return value.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    }
}
