import AVFoundation
import Darwin
import Foundation

final class RecoveryStore {
    private struct Span: Codable {
        var startFrame: Int64
        var frameCount: Int64

        var endFrame: Int64 { startFrame + frameCount }
    }

    private struct Manifest: Codable {
        var version = 1
        var sampleRate = 48_000
        var channels = 2
        var audioFile = "audio.caf"
        var rawFile: String?
        var audioFrames: Int64
        var timelineFrames: Int64
        var spans: [Span]
        var snapshot: SessionSnapshot
    }

    private struct StorageError: Error, CustomStringConvertible, LocalizedError {
        let reason: String
        let directory: String

        var description: String { "\(reason). Recovery materials: \(directory)" }
        var errorDescription: String? { description }
    }

    private enum State {
        case active
        case failed(String)
        case finalized
    }

    private static let sampleRate = 48_000.0
    private static let headerBytes: Int64 = 68
    private static let maximumManifestBytes = 8 * 1_024 * 1_024
    private static let maximumSpans = 100_000
    private static let maximumFrames = Int64.max / 16
    private let directory: URL
    private let directoryFD: Int32
    private let lockFD: Int32
    private let audioFD: Int32
    private let rawFD: Int32?
    private var manifest: Manifest
    private var state = State.active

    init(directory: URL, keepRaw: Bool, snapshot: SessionSnapshot) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let directoryFD = try Self.openDirectory(directory)
        var lockFD: Int32 = -1
        var audioFD: Int32 = -1
        var rawFD: Int32?
        do {
            lockFD = try Self.acquireLock(directoryFD, directory: directory)
            try Self.validateSnapshot(snapshot, directory: directory)
            for name in ["audio.caf", "microphone.caf", "manifest.json"] {
                var info = stat()
                guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                    throw Self.error("The recovery directory already contains recording materials", directory: directory)
                }
            }
            audioFD = try Self.createFile("audio.caf", in: directoryFD, directory: directory)
            try Self.writeAll(Self.cafHeader(channels: 2), to: audioFD, directory: directory)
            if keepRaw {
                rawFD = try Self.createFile("microphone.caf", in: directoryFD, directory: directory)
                try Self.writeAll(Self.cafHeader(channels: 1), to: rawFD!, directory: directory)
            }
        } catch {
            if let rawFD { close(rawFD) }
            if audioFD >= 0 { close(audioFD) }
            if lockFD >= 0 { close(lockFD) }
            close(directoryFD)
            throw error
        }
        self.directory = directory
        self.directoryFD = directoryFD
        self.lockFD = lockFD
        self.audioFD = audioFD
        self.rawFD = rawFD
        self.manifest = Manifest(rawFile: keepRaw ? "microphone.caf" : nil,
                                 audioFrames: 0, timelineFrames: 0, spans: [], snapshot: snapshot)
        try checkpoint(snapshot)
    }

    private init(recovering directory: URL) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let directoryFD = try Self.openDirectory(directory)
        var lockFD: Int32 = -1
        var audioFD: Int32 = -1
        var rawFD: Int32?
        let manifest: Manifest
        do {
            lockFD = try Self.acquireLock(directoryFD, directory: directory)
            manifest = try Self.readManifest(in: directoryFD, directory: directory)
            audioFD = try Self.openAudio("audio.caf", channels: 2, frames: manifest.audioFrames,
                                         in: directoryFD, directory: directory)
            if manifest.rawFile != nil {
                rawFD = try Self.openAudio("microphone.caf", channels: 1, frames: manifest.audioFrames,
                                           in: directoryFD, directory: directory)
            }
        } catch {
            if let rawFD { close(rawFD) }
            if audioFD >= 0 { close(audioFD) }
            if lockFD >= 0 { close(lockFD) }
            close(directoryFD)
            throw error
        }
        self.directory = directory
        self.directoryFD = directoryFD
        self.lockFD = lockFD
        self.audioFD = audioFD
        self.rawFD = rawFD
        self.manifest = manifest
    }

    deinit {
        close(audioFD)
        if let rawFD { close(rawFD) }
        if case .finalized = state {
            unlinkat(directoryFD, "writer.lock", 0)
            rmdir(directory.path)
        }
        close(lockFD)
        close(directoryFD)
    }

    func append(stereo: [Float], rawMicrophone: [Float]?, at frame: Int64) throws {
        try requireWritable()
        let frameCount = Int64(stereo.count / 2)
        guard !stereo.isEmpty, stereo.count.isMultiple(of: 2), frame >= 0,
              frame <= Self.maximumFrames - frameCount,
              frame >= (manifest.spans.last?.endFrame ?? 0),
              manifest.audioFrames <= Self.maximumFrames - frameCount,
              stereo.allSatisfy(\.isFinite) else {
            throw error("Invalid or overlapping stereo audio frames")
        }
        if rawFD != nil {
            guard let rawMicrophone, rawMicrophone.count == Int(frameCount),
                  rawMicrophone.allSatisfy(\.isFinite) else {
                throw error("Raw microphone frames do not match the stereo audio")
            }
        }
        guard manifest.spans.last?.endFrame == frame || manifest.spans.count < Self.maximumSpans else {
            throw error("The recovery timeline has too many separate audio spans")
        }
        do {
            try stereo.withUnsafeBytes { try Self.writeAll($0, to: audioFD, directory: directory) }
            if let rawFD, let rawMicrophone {
                try rawMicrophone.withUnsafeBytes { try Self.writeAll($0, to: rawFD, directory: directory) }
            }
            if manifest.spans.last?.endFrame == frame {
                manifest.spans[manifest.spans.count - 1].frameCount += frameCount
            } else {
                manifest.spans.append(Span(startFrame: frame, frameCount: frameCount))
            }
            manifest.audioFrames += frameCount
        } catch {
            state = .failed(String(describing: error))
            throw error
        }
    }

    @discardableResult
    func checkpoint(_ snapshot: SessionSnapshot) throws -> Int64 {
        try requireWritable()
        try Self.validateSnapshot(snapshot, directory: directory)
        guard snapshot.sessionID == manifest.snapshot.sessionID else {
            throw error("The checkpoint belongs to another recording session")
        }
        var next = manifest
        next.timelineFrames = max(manifest.spans.last?.endFrame ?? 0,
                                  Int64((snapshot.elapsedSeconds * Self.sampleRate).rounded(.down)))
        guard next.timelineFrames >= manifest.timelineFrames else {
            throw error("The checkpoint would move the committed timeline backwards")
        }
        next.snapshot = snapshot
        next.snapshot.recoveryPath = directory.path
        next.snapshot.elapsedSeconds = Double(next.timelineFrames) / Self.sampleRate
        next.snapshot.committedSeconds = next.snapshot.elapsedSeconds
        next.snapshot.outputPath = nil
        next.snapshot.rawOutputPath = nil
        do {
            try Self.sync(audioFD, directory: directory)
            if let rawFD { try Self.sync(rawFD, directory: directory) }
            let data = try Self.encoder().encode(next)
            guard data.count <= Self.maximumManifestBytes else {
                throw error("The recovery manifest exceeds the supported size")
            }
            try Self.replaceManifest(data, in: directoryFD, directory: directory)
            manifest = next
            return next.timelineFrames
        } catch {
            state = .failed(String(describing: error))
            throw error
        }
    }

    func finalize(_ snapshot: SessionSnapshot, outputDirectory: URL) throws -> SessionSnapshot {
        try checkpoint(snapshot)
        return try encode(outputDirectory: outputDirectory)
    }

    static func recover(directory: URL, outputDirectory: URL) throws -> SessionSnapshot {
        let store = try RecoveryStore(recovering: directory)
        return try store.encode(outputDirectory: outputDirectory)
    }

    private func encode(outputDirectory: URL) throws -> SessionSnapshot {
        try requireWritable()
        guard manifest.timelineFrames > 0 else { throw error("There is no committed audio timeline to recover") }
        let outputDirectory = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let outputFD = try Self.openDirectory(outputDirectory)
        defer { close(outputFD) }
        let stem = "meetingtape-\(manifest.snapshot.sessionID)-\(UUID().uuidString.lowercased())"
        let audioName = stem + ".m4a"
        let rawName = stem + "-microphone.caf"
        let metadataName = stem + ".json"
        let audioStage = "." + audioName + ".partial.m4a"
        let rawStage = "." + rawName + ".partial.caf"
        let metadataStage = "." + metadataName + ".partial"
        do {
            try writeTrack(from: audioFD, channels: 2, to: outputDirectory.appendingPathComponent(audioStage), aac: true)
            if let rawFD {
                try writeTrack(from: rawFD, channels: 1, to: outputDirectory.appendingPathComponent(rawStage), aac: false)
            }
            try Self.publish(audioStage, as: audioName, in: outputFD, directory: directory)
            if rawFD != nil { try Self.publish(rawStage, as: rawName, in: outputFD, directory: directory) }
            var completed = manifest.snapshot
            completed.state = .completed
            completed.failureReason = nil
            completed.outputPath = outputDirectory.appendingPathComponent(audioName).path
            completed.rawOutputPath = rawFD == nil ? nil : outputDirectory.appendingPathComponent(rawName).path
            let metadataFD = try Self.createFile(metadataStage, in: outputFD, directory: directory)
            do {
                try Self.writeAll(try Self.encoder().encode(completed), to: metadataFD, directory: directory)
                try Self.sync(metadataFD, directory: directory)
                close(metadataFD)
            } catch {
                close(metadataFD)
                throw error
            }
            try Self.publish(metadataStage, as: metadataName, in: outputFD, directory: directory)
            try Self.sync(outputFD, directory: directory)
            state = .finalized
            for name in ["audio.caf", "microphone.caf", "manifest.json"] {
                unlinkat(directoryFD, name, 0)
            }
            for name in [audioStage, rawStage, metadataStage] {
                unlinkat(outputFD, name, 0)
            }
            return completed
        } catch {
            throw self.error("Finalization failed: \(error)")
        }
    }

    private func writeTrack(from sourceFD: Int32, channels: Int, to url: URL, aac: Bool) throws {
        let reservation = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard reservation >= 0 else { throw error("Cannot reserve encoded output: \(Self.systemReason())") }
        close(reservation)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                   channels: AVAudioChannelCount(channels), interleaved: true)!
        let settings: [String: Any] = aac
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
               AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 192_000]
            : format.settings
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings,
                                                  commonFormat: .pcmFormatFloat32, interleaved: true)
        defer { writer = nil }
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw error("Cannot allocate an encoding buffer")
        }
        func writeFrames(_ count: Int64, compactOffset: Int64?) throws {
            var remaining = count
            var offset = compactOffset ?? 0
            while remaining > 0 {
                let frames = Int(min(remaining, Int64(capacity)))
                let byteCount = frames * channels * MemoryLayout<Float>.size
                if compactOffset != nil {
                    try Self.readAll(into: samples, count: byteCount, from: sourceFD,
                                     offset: Self.headerBytes + offset * Int64(channels * 4), directory: directory)
                    let floats = UnsafeBufferPointer(start: samples.assumingMemoryBound(to: Float.self),
                                                     count: frames * channels)
                    guard floats.allSatisfy(\.isFinite) else { throw error("Committed audio contains nonfinite samples") }
                } else {
                    memset(samples, 0, byteCount)
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                try writer!.write(from: buffer)
                remaining -= Int64(frames)
                offset += Int64(frames)
            }
        }
        var cursor: Int64 = 0
        var compactOffset: Int64 = 0
        for span in manifest.spans {
            try writeFrames(span.startFrame - cursor, compactOffset: nil)
            try writeFrames(span.frameCount, compactOffset: compactOffset)
            compactOffset += span.frameCount
            cursor = span.endFrame
        }
        try writeFrames(manifest.timelineFrames - cursor, compactOffset: nil)
        writer = nil
        let encodedFD = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard encodedFD >= 0 else { throw error("Cannot reopen encoded audio") }
        defer { close(encodedFD) }
        try Self.sync(encodedFD, directory: directory)
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        guard reader.processingFormat.channelCount == channels,
              reader.processingFormat.sampleRate == Self.sampleRate,
              reader.length > 0, abs(reader.length - manifest.timelineFrames) <= (aac ? 4_096 : 0) else {
            throw error("Encoded audio has an unexpected format or duration")
        }
        try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), reader.length)))
        guard buffer.frameLength > 0 else { throw error("Encoded audio cannot be decoded") }
        reader.framePosition = max(0, reader.length - Int64(capacity))
        try reader.read(into: buffer, frameCount: capacity)
        guard buffer.frameLength > 0 else { throw error("The encoded audio tail cannot be decoded") }
    }

    private func requireWritable() throws {
        switch state {
        case .active: return
        case .failed(let reason): throw error(reason)
        case .finalized: throw error("The recording is already finalized")
        }
    }

    private func error(_ reason: String) -> StorageError {
        Self.error(reason, directory: directory)
    }

    private static func error(_ reason: String, directory: URL) -> StorageError {
        StorageError(reason: reason, directory: directory.path)
    }

    private static func validateSnapshot(_ snapshot: SessionSnapshot, directory: URL) throws {
        let id = snapshot.sessionID.utf8
        guard snapshot.schemaVersion == 1, !id.isEmpty, id.count <= 128,
              id.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }),
              URL(fileURLWithPath: snapshot.recoveryPath).standardizedFileURL.resolvingSymlinksInPath() == directory,
              snapshot.elapsedSeconds.isFinite, snapshot.elapsedSeconds >= 0,
              snapshot.elapsedSeconds <= Double(maximumFrames) / sampleRate,
              snapshot.committedSeconds.isFinite, snapshot.committedSeconds >= 0,
              snapshot.interruptions.count <= maximumSpans, snapshot.degradedIntervals.count <= maximumSpans,
              (snapshot.interruptions + snapshot.degradedIntervals).allSatisfy({
                  $0.startSeconds.isFinite && $0.endSeconds.isFinite && $0.startSeconds >= 0 && $0.endSeconds >= $0.startSeconds
              }) else {
            throw error("Invalid recording snapshot in the recovery manifest", directory: directory)
        }
    }

    private static func readManifest(in directoryFD: Int32, directory: URL) throws -> Manifest {
        let fd = openat(directoryFD, "manifest.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("Cannot open the committed recovery manifest: \(systemReason())", directory: directory) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumManifestBytes else {
            throw error("Invalid recovery manifest file or size", directory: directory)
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes {
            try readAll(into: $0.baseAddress!, count: $0.count, from: fd, offset: 0, directory: directory)
        }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw self.error("Cannot decode the committed recovery manifest: \(error)", directory: directory) }
        try validateSnapshot(manifest.snapshot, directory: directory)
        guard manifest.version == 1, manifest.sampleRate == 48_000, manifest.channels == 2,
              manifest.audioFile == "audio.caf", manifest.rawFile == nil || manifest.rawFile == "microphone.caf",
              manifest.audioFrames >= 0, manifest.audioFrames <= maximumFrames,
              manifest.timelineFrames >= 0, manifest.timelineFrames <= maximumFrames,
              manifest.spans.count <= maximumSpans,
              abs(manifest.snapshot.committedSeconds - Double(manifest.timelineFrames) / sampleRate) < 1 / sampleRate,
              abs(manifest.snapshot.elapsedSeconds - Double(manifest.timelineFrames) / sampleRate) < 1 / sampleRate else {
            throw error("Unsupported or inconsistent recovery manifest", directory: directory)
        }
        var end: Int64 = 0
        var frames: Int64 = 0
        for span in manifest.spans {
            guard span.startFrame >= end, span.frameCount > 0,
                  span.startFrame <= maximumFrames - span.frameCount,
                  frames <= maximumFrames - span.frameCount else {
                throw error("Invalid audio spans in the recovery manifest", directory: directory)
            }
            end = span.endFrame
            frames += span.frameCount
        }
        guard frames == manifest.audioFrames, end <= manifest.timelineFrames else {
            throw error("The committed audio extent does not match its timeline", directory: directory)
        }
        return manifest
    }

    private static func openAudio(_ name: String, channels: Int, frames: Int64,
                                  in directoryFD: Int32, directory: URL) throws -> Int32 {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("Cannot open committed \(name): \(systemReason())", directory: directory) }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= headerBytes + frames * Int64(channels * 4) else {
                throw error("Committed \(name) is truncated or is not a regular file", directory: directory)
            }
            var header = Data(count: Int(headerBytes))
            try header.withUnsafeMutableBytes {
                try readAll(into: $0.baseAddress!, count: $0.count, from: fd, offset: 0, directory: directory)
            }
            guard header == cafHeader(channels: channels) else {
                throw error("Unsupported CAF header in \(name)", directory: directory)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func cafHeader(channels: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.bigEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "caff".utf8)
        append(UInt16(1))
        append(UInt16(0))
        data.append(contentsOf: "desc".utf8)
        append(UInt64(32))
        append(sampleRate.bitPattern)
        data.append(contentsOf: "lpcm".utf8)
        append(UInt32(9))
        append(UInt32(channels * 4))
        append(UInt32(1))
        append(UInt32(channels))
        append(UInt32(32))
        data.append(contentsOf: "data".utf8)
        append(UInt64.max)
        append(UInt32(0))
        return data
    }

    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("Cannot open the existing directory: \(systemReason())", directory: directory) }
        return fd
    }

    private static func acquireLock(_ directoryFD: Int32, directory: URL) throws -> Int32 {
        let fd = openat(directoryFD, "writer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error("Cannot open the recovery lock: \(systemReason())", directory: directory) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(fd)
            throw error("The recovery lock is not a private regular file", directory: directory)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw error("This recovery directory has an active writer or recovery process", directory: directory)
        }
        return fd
    }

    private static func createFile(_ name: String, in directoryFD: Int32, directory: URL) throws -> Int32 {
        let fd = openat(directoryFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error("Cannot create \(name): \(systemReason())", directory: directory) }
        return fd
    }

    private static func replaceManifest(_ data: Data, in directoryFD: Int32, directory: URL) throws {
        let name = "manifest-\(UUID().uuidString.lowercased()).tmp"
        let fd = try createFile(name, in: directoryFD, directory: directory)
        defer { close(fd) }
        try writeAll(data, to: fd, directory: directory)
        try sync(fd, directory: directory)
        guard renameat(directoryFD, name, directoryFD, "manifest.json") == 0 else {
            throw error("Cannot publish the recovery checkpoint: \(systemReason())", directory: directory)
        }
        try sync(directoryFD, directory: directory)
    }

    private static func publish(_ stage: String, as name: String, in directoryFD: Int32, directory: URL) throws {
        guard linkat(directoryFD, stage, directoryFD, name, 0) == 0 else {
            throw error("Cannot publish \(name) without overwriting an existing file: \(systemReason())", directory: directory)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func writeAll(_ data: Data, to fd: Int32, directory: URL) throws {
        try data.withUnsafeBytes { try writeAll($0, to: fd, directory: directory) }
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to fd: Int32, directory: URL) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw error("Cannot write recovery data: \(systemReason())", directory: directory) }
            offset += count
        }
    }

    private static func readAll(into buffer: UnsafeMutableRawPointer, count: Int, from fd: Int32,
                                offset: Int64, directory: URL) throws {
        var readCount = 0
        while readCount < count {
            let result = pread(fd, buffer.advanced(by: readCount), count - readCount, offset + Int64(readCount))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw error("Cannot read the committed audio extent: \(systemReason())", directory: directory) }
            readCount += result
        }
    }

    private static func sync(_ fd: Int32, directory: URL) throws {
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw error("Cannot synchronize recovery data: \(systemReason())", directory: directory)
        }
    }

    private static func systemReason() -> String {
        String(cString: strerror(errno))
    }
}
