import AVFoundation
import Foundation
import Testing
@testable import MeetingTapeTranscription

@Test func comparisonMatchesTimeDespiteDifferentSentenceBoundaries() {
    let segment = TranscriptSegment(id: 0, start: 5, end: 9, text: "稍后继续")
    let other = TranscriptResult(model: .moss, revision: "fixture", segments: [
        TranscriptSegment(id: 0, start: 0, end: 2, text: "开始"),
        TranscriptSegment(id: 1, start: 5, end: 7, text: "稍后"),
        TranscriptSegment(id: 2, start: 7, end: 9, text: "继续")])
    #expect(TranscriptComparison.matching(segment, in: other).map(\.id) == [1, 2])
    #expect(!TranscriptComparison.differs("稍后继续。", from: "稍后 继续"))
    #expect(TranscriptComparison.differs("不会继续", from: "会继续"))
}

@Test func cloudTimestampsUseSecondsAndKeepRealSpeakerLabels() throws {
    let response = Doubao.Response(code: "20000000", logID: nil, body: ["result": ["utterances": [
        ["start_time": 1200.0, "end_time": 2600.0, "text": "你好", "additions": ["speaker": "2"]],
        ["start_time": -10.0, "end_time": 500.0, "text": "invalid"]]]])
    let result = try Doubao.parse(response, duration: 2)
    #expect(result.segments.count == 1)
    #expect(result.segments[0].start == 1.2)
    #expect(result.segments[0].end == 2)
    #expect(result.segments[0].speaker == "2")
}

@Test func savingOldPreferencesPreservesNewlyActivatedModel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-settings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(root: root)
    var draft = try store.settings()
    let installation = LocalInstallation(family: "qwen", profile: "low-memory", python: "/python", model: "/model", revision: "fixed", repository: "fixture", runtimeVersion: "fixture", ready: true)
    try store.activate(installation)
    draft.models = [.qwen, .doubao]
    try store.saveSettings(draft)
    let saved = try store.settings()
    #expect(saved.models == [.qwen, .doubao])
    #expect(saved.installations["qwen"] == installation)
}

@Test func legacyCloudTaskKeepsItsMergedRequestAndProgress() throws {
    let data = Data("""
    {"schemaVersion":1,"id":"1d2b32c3-6b8e-4b03-95c2-8e302c8a9be0","inputPath":"/fixture.m4a","inputSHA256":"fixture","duration":20,"createdAt":"2026-10-29T00:00:00Z","primaryModel":"doubao","runs":[{"model":"doubao","revision":"fixture","state":"failed","completedChunks":1,"cloudRequestID":"original-request","cloudSubmission":"submitting"}]}
    """.utf8)
    let task = try JSONDecoder().decode(TranscriptionTask.self, from: data)
    #expect(task.recognitionMode == .merged)
    #expect(task.runs[0].sources.count == 1)
    #expect(task.runs[0].sources[0].source == .merged)
    #expect(task.runs[0].sources[0].cloudRequestID == "original-request")
    #expect(task.runs[0].sources[0].cloudSubmission == "submitting")
    #expect(task.runs[0].sources[0].completedChunks == 1)
    let restored = try JSONDecoder().decode(TranscriptionTask.self, from: JSONEncoder().encode(task))
    #expect(restored.runs[0].sources[0].cloudRequestID == "original-request")
}

@Test func failedSourcePreservesOtherSourceAndPartialText() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-sources-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(root: root)
    var run = TranscriptRun(model: .qwen, revision: "fixture", sources: [.system, .microphone])
    run.sources[0].state = .succeeded
    run.sources[1].state = .failed
    run.sources[1].completedChunks = 1
    let task = TranscriptionTask(schemaVersion: 2, id: UUID().uuidString.lowercased(), inputPath: "/fixture.m4a", inputSHA256: "fixture", duration: 60, createdAt: "2026-10-29T00:00:00Z", primaryModel: .qwen, runs: [run], recognitionMode: .separate, nativeSourceMapping: true)
    try TranscriptionStore.directory(store.taskDirectory(task.id))
    try store.save(task)
    let system = TranscriptResult(model: .qwen, revision: "fixture", segments: [TranscriptSegment(id: 0, start: 1, end: 4, text: "系统原文", source: .system)])
    let microphone = TranscriptResult(model: .qwen, revision: "fixture", segments: [TranscriptSegment(id: 1, start: 2, end: 5, text: "麦克风部分原文", source: .microphone)])
    let systemPath = try store.resultPath(task.id, model: .qwen, source: .system)
    try store.write(system, to: systemPath)
    let before = try Data(contentsOf: systemPath)
    try store.write(LocalProgress(result: microphone, completedChunks: 1), to: store.resultPath(task.id, model: .qwen, source: .microphone, partial: true))
    let combined = try store.result(task.id, model: .qwen)
    #expect(task.finished && task.state == "partial")
    #expect(combined.partial)
    #expect(combined.segments.map(\.source) == [.system, .microphone])
    #expect(TranscriptComparison.matching(system.segments[0], in: microphone).isEmpty)
    #expect(try Data(contentsOf: systemPath) == before)
}

@Test func localLockDistinguishesInferenceContentionFromRecordingPriority() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-lock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(root: root)

    do {
        let inference = try TranscriptionLock(root.appendingPathComponent("inference.lock"))
        defer { withExtendedLifetime(inference) {} }
        let outcome = try TranscriptionProcess.local(store: store, recordingActive: { false }) { _ in true }
        guard case .waitingForInference = outcome else {
            Issue.record("inference.lock contention without recording should report waitingForInference")
            return
        }
    }

    do {
        let intent = try TranscriptionLock(root.appendingPathComponent("recording-intent.lock"))
        defer { withExtendedLifetime(intent) {} }
        let outcome = try TranscriptionProcess.local(store: store, recordingActive: { false }) { _ in true }
        guard case .waitingForRecording = outcome else {
            Issue.record("recording-intent.lock should report waitingForRecording")
            return
        }
    }

    let activeRecording = try TranscriptionProcess.local(store: store, recordingActive: { true }) { _ in true }
    guard case .waitingForRecording = activeRecording else {
        Issue.record("active recording should report waitingForRecording")
        return
    }

    let executed = try TranscriptionProcess.local(store: store, recordingActive: { false }) { _ in true }
    guard case .executed(true) = executed else {
        Issue.record("unlocked local execution should succeed")
        return
    }

    // Shared lock probes must not block each other or falsely report recordingRequested.
    let sharedProbe = try TranscriptionLock(root.appendingPathComponent("recording-intent.lock"), shared: true)
    defer { withExtendedLifetime(sharedProbe) {} }
    #expect(!TranscriptionProcess.recordingRequested(in: store))
}

@Test func separateSourceSegmentIDsStayLinearAcrossChunksAndRetries() throws {
    let systemSegments = (0..<70).map { i in
        TranscriptSegment(id: TranscriptSource.system.segmentID(i), start: Double(i), end: Double(i) + 1, text: "s\(i)", source: .system)
    }
    let micSegments = (0..<70).map { i in
        TranscriptSegment(id: TranscriptSource.microphone.segmentID(i), start: Double(i), end: Double(i) + 1, text: "m\(i)", source: .microphone)
    }
    #expect(TranscriptSource.system.nextSegmentIndex(after: []) == 0)
    #expect(TranscriptSource.microphone.nextSegmentIndex(after: []) == 0)
    #expect(TranscriptSource.system.nextSegmentIndex(after: systemSegments) == 70)
    #expect(TranscriptSource.microphone.nextSegmentIndex(after: micSegments) == 70)
    #expect(TranscriptSource.system.segmentID(TranscriptSource.system.nextSegmentIndex(after: systemSegments)) == 140)
    #expect(TranscriptSource.microphone.segmentID(TranscriptSource.microphone.nextSegmentIndex(after: micSegments)) == 141)
}

private func writeSilentWAV(at url: URL, seconds: Int) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
    buffer.frameLength = 16000
    if let channel = buffer.int16ChannelData?[0] { channel.initialize(repeating: 0, count: 16000) }
    for _ in 0..<seconds { try file.write(from: buffer) }
}

private func makeMockLocalTask(root: URL, seconds: Int, scriptBody: String) throws -> (TranscriptionStore, TranscriptionTask, URL) {
    let store = try TranscriptionStore(root: root.appendingPathComponent("store"))
    let audio = root.appendingPathComponent("input.wav")
    try writeSilentWAV(at: audio, seconds: seconds)
    let modelDir = root.appendingPathComponent("model")
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))
    let python = root.appendingPathComponent("mock-runner.sh")
    try Data(scriptBody.utf8).write(to: python)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
    let runner = root.appendingPathComponent("local_runner.py")
    try Data("# mock\n".utf8).write(to: runner)
    let installation = LocalInstallation(family: "moss", profile: "low-memory", python: python.path, model: modelDir.path, revision: "fixture", repository: "fixture", runtimeVersion: "fixture", ready: true)
    let run = TranscriptRun(model: .moss, installation: installation, revision: "fixture", sources: [.merged])
    let task = TranscriptionTask(schemaVersion: 2, id: UUID().uuidString.lowercased(), inputPath: audio.path, inputSHA256: try TranscriptionStore.fingerprint(audio), duration: Double(seconds), createdAt: "2026-11-26T00:00:00Z", primaryModel: .moss, runs: [run], recognitionMode: .merged, nativeSourceMapping: false)
    try TranscriptionStore.directory(store.taskDirectory(task.id))
    try store.save(task)
    return (store, task, runner)
}

@Test func decoderExhaustedChunkIsSkippedAndRetriedWithoutBlockingRemainingChunks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-exhaust-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let logFile = root.appendingPathComponent("calls.log")
    let recoverFlag = root.appendingPathComponent("recover")
    let script = """
    #!/bin/sh
    audio=""
    output=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --audio) audio="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    base=$(basename "$audio")
    echo "$base" >> "\(logFile.path)"
    case "$base" in
      *-0.wav)
        if [ -f "\(recoverFlag.path)" ]; then
          printf '{"text":"第一块恢复原文","segments":[{"start":1.0,"end":4.0,"text":"第一块恢复原文","speaker":"S01"}],"timestampPrecision":"segment","raw":{}}\n' > "$output"
          exit 0
        fi
        printf '{"error":"MOSS 生成达到上限","errorCode":"decoder_exhausted","raw":{"text":"loop"}}\n' > "$output"
        echo "MOSS 生成达到上限" >&2
        exit 1
        ;;
      *-1.wav)
        printf '{"text":"第二块原文","segments":[{"start":2.0,"end":5.0,"text":"第二块原文","speaker":"S01"}],"timestampPrecision":"segment","raw":{}}\n' > "$output"
        exit 0
        ;;
      *)
        printf '{"text":"第三块原文","segments":[{"start":3.0,"end":6.0,"text":"第三块原文","speaker":"S01"}],"timestampPrecision":"segment","raw":{}}\n' > "$output"
        exit 0
        ;;
    esac
    """
    let (store, task, runner) = try makeMockLocalTask(root: root, seconds: 90, scriptBody: script)

    try TranscriptionManager.work(task.id, store: store, runner: runner)
    var updated = try store.task(task.id)
    #expect(updated.state == "partial")
    #expect(updated.runs[0].state == .partial)
    #expect(updated.runs[0].sources[0].state == .partial)
    #expect(updated.runs[0].sources[0].completedChunks == 2)
    #expect(updated.runs[0].sources[0].error?.contains("00:00–00:30") == true)
    #expect(updated.runs[0].sources[0].error?.contains("2/3") == true)
    #expect(!FileManager.default.fileExists(atPath: try store.resultPath(task.id, model: .moss, source: .merged).path))
    let partialResult = try store.result(task.id, model: .moss)
    #expect(partialResult.partial)
    #expect(partialResult.segments.map(\.text) == ["第二块原文", "第三块原文"])
    let partialMarkdown = try TranscriptExportSnapshot.load(task.id, store: store, captions: LiveCaptionStore(directory: root.appendingPathComponent("captions"))).markdown(primary: task.id + ":moss")
    #expect(partialMarkdown.contains("00:00–00:30"))
    #expect(partialMarkdown.contains("不含跳过块"))
    #expect(!partialMarkdown.contains("0–00:01:00.000"))

    try Data("ok".utf8).write(to: recoverFlag)
    try Data().write(to: logFile)
    updated.runs[0].sources[0].state = .queued
    updated.runs[0].sources[0].error = nil
    try store.save(updated)

    try TranscriptionManager.work(task.id, store: store, runner: runner)
    let retried = try store.task(task.id)
    #expect(retried.state == "completed")
    #expect(retried.runs[0].sources[0].state == .succeeded)
    #expect(retried.runs[0].sources[0].error == nil)
    #expect(retried.runs[0].sources[0].completedChunks == 3)
    let retriedCalls = try String(contentsOf: logFile, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(retriedCalls == ["local-moss-0.wav"])
    let finalResult = try store.result(task.id, model: .moss)
    #expect(!finalResult.partial)
    #expect(finalResult.segments.map(\.text) == ["第一块恢复原文", "第二块原文", "第三块原文"])
    #expect(Set(finalResult.segments.map(\.id)).count == 3)
}

@Test func nonExhaustionErrorStillAbortsImmediatelyAndAllExhaustedFails() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-fail-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let crashLog = root.appendingPathComponent("crash.log")
    let crashScript = """
    #!/bin/sh
    audio=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --audio) audio="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo "$(basename "$audio")" >> "\(crashLog.path)"
    echo "fatal runtime error" >&2
    exit 1
    """
    let (crashStore, crashTask, crashRunner) = try makeMockLocalTask(root: root.appendingPathComponent("crash"), seconds: 90, scriptBody: crashScript)
    try TranscriptionManager.work(crashTask.id, store: crashStore, runner: crashRunner)
    let crashed = try crashStore.task(crashTask.id)
    #expect(crashed.runs[0].sources[0].state == .failed)
    let crashCalls = try String(contentsOf: crashLog, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(crashCalls == ["local-moss-0.wav"])

    let exhaustScript = """
    #!/bin/sh
    output=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --output) output="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '{"error":"MOSS 生成达到上限","errorCode":"decoder_exhausted","raw":{"text":"loop"}}\n' > "$output"
    exit 1
    """
    let (allStore, allTask, allRunner) = try makeMockLocalTask(root: root.appendingPathComponent("all"), seconds: 60, scriptBody: exhaustScript)
    try TranscriptionManager.work(allTask.id, store: allStore, runner: allRunner)
    let failedAll = try allStore.task(allTask.id)
    #expect(failedAll.runs[0].sources[0].state == .failed)
    #expect(failedAll.runs[0].sources[0].completedChunks == 0)
    #expect(failedAll.runs[0].sources[0].error?.contains("全部 2 个音频块") == true)
}
