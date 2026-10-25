import CryptoKit
import Darwin
import Foundation
import MeetingTapeCore

struct HostFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct HostResponse: Codable, Sendable {
    var snapshot: SessionSnapshot?
    var error: String?
}

enum HostRequest: Codable, Equatable {
    case status
    case stop
    case stopSession(String)

    var isStop: Bool { self != .status }

    private enum CodingKeys: String, CodingKey { case command, sessionID }

    init(from decoder: any Decoder) throws {
        if let command = try? decoder.singleValueContainer().decode(String.self) {
            switch command {
            case "status": self = .status
            case "stop": self = .stop
            default: throw HostFailure("unknown host request")
            }
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(String.self, forKey: .command) == "stop" else { throw HostFailure("unknown host request") }
            self = .stopSession(try container.decode(String.self, forKey: .sessionID))
        }
    }

    func encode(to encoder: any Encoder) throws {
        if case .stopSession(let id) = self {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("stop", forKey: .command)
            try container.encode(id, forKey: .sessionID)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(self == .status ? "status" : "stop")
        }
    }
}

struct HostPaths: Sendable {
    let directory: URL
    let socketPath: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let root = environment["MEETINGTAPE_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeetingTape", isDirectory: true)
        directory = root.standardizedFileURL.resolvingSymlinksInPath()
        try Self.privateDirectory(directory)
        let digest = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let transport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetingtape-\(getuid())-\(digest)", isDirectory: true)
        try Self.privateDirectory(transport)
        socketPath = transport.appendingPathComponent("host.sock").path
    }

    private static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw HostFailure("state directory must be owned by the current user and have mode 700: \(url.path)")
        }
    }
}

final class SessionLock {
    private let descriptor: Int32

    init(directory: URL, name: String, wait: Bool = false) throws {
        descriptor = open(directory.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw HostFailure("cannot open the session lock") }
        let mode = LOCK_EX | (wait ? 0 : LOCK_NB)
        var result = flock(descriptor, mode)
        while result != 0 && errno == EINTR { result = flock(descriptor, mode) }
        guard result == 0 else {
            throw HostFailure("another recording session is starting or active")
        }
    }

    deinit { close(descriptor) }
}

enum SessionCache {
    static func store(_ snapshot: SessionSnapshot, paths: HostPaths, replacing sessionID: String? = nil) throws {
        let lock = try SessionLock(directory: paths.directory, name: "snapshot.lock", wait: true)
        defer { withExtendedLifetime(lock) {} }
        let file = paths.directory.appendingPathComponent("last-session.json")
        let previous = (try? Data(contentsOf: file)).flatMap {
            try? JSONDecoder().decode(SessionSnapshot.self, from: $0)
        }
        if let sessionID {
            guard previous?.sessionID == sessionID else { return }
        }
        if previous?.sessionID == snapshot.sessionID, previous?.state == .completed, snapshot.state != .completed {
            return
        }
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }
}

enum HostTransport {
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else {
            throw HostFailure("local socket path is too long")
        }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { target in target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return value
    }

    static func socket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HostFailure("cannot create the local session socket") }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var timeout = timeval(tv_sec: 600, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        return descriptor
    }

    static func request(_ request: HostRequest, paths: HostPaths) throws -> HostResponse? {
        let descriptor = try socket()
        defer { close(descriptor) }
        var responseTimeout = timeval(tv_sec: request.isStop ? 0 : 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &responseTimeout, socklen_t(MemoryLayout.size(ofValue: responseTimeout)))
        var target = try address(paths.socketPath)
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { return nil }
            throw HostFailure("cannot connect to the recording host: \(String(cString: strerror(errno)))")
        }
        try write(request, to: descriptor)
        return try read(HostResponse.self, from: descriptor)
    }

    static func write<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HostFailure("local session socket write failed") }
                offset += count
            }
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from descriptor: Int32) throws -> T {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while data.count < 8 * 1_048_576 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw HostFailure("recording host disconnected or timed out before replying") }
            if let newline = bytes.prefix(count).firstIndex(of: 0x0A) {
                data.append(contentsOf: bytes[..<newline])
                return try JSONDecoder().decode(type, from: data)
            }
            data.append(contentsOf: bytes.prefix(count))
        }
        throw HostFailure("recording host response exceeds the size limit")
    }
}
