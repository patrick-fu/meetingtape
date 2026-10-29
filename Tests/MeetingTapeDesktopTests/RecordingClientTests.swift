import Foundation
import XCTest
@testable import MeetingTapeDesktop

final class RecordingClientTests: XCTestCase {
    func testExitedCommandsReleaseClientForTheNextCommand() async {
        let completed = expectation(description: "退出的命令返回结果并允许下一次调用")
        let client = RecordingClient(executable: URL(fileURLWithPath: "/bin/echo"))
        let task = Task {
            do {
                for _ in 0..<10 {
                    let result = try await client.run([#"{"schemaVersion":1,"state":"idle"}"#])
                    XCTAssertNil(result)
                }
            } catch { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        task.cancel()
    }

    func testEmptyFailureAndSignalExitReturnAnExplanation() async {
        let completed = expectation(description: "失败或信号退出都返回可读错误")
        let client = RecordingClient(executable: URL(fileURLWithPath: "/bin/sh"))
        let task = Task {
            for command in ["exit 7", "kill -TERM $$"] {
                do {
                    _ = try await client.run(["-c", command])
                    XCTFail("失败的命令不能返回成功")
                } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        task.cancel()
    }

    func testBothPipesDrainAndLaunchFailureReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("invalid-executable")
        try Data("not an executable\n".utf8).write(to: invalid)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: invalid.path)
        let completed = expectation(description: "大输出和启动失败不会阻塞")
        let task = Task {
            do {
                let client = RecordingClient(executable: URL(fileURLWithPath: "/usr/bin/awk"))
                let result = try await client.run([#"BEGIN { for (i = 0; i < 131072; i++) printf "diagnostic line\n" > "/dev/stderr"; print "{\"schemaVersion\":1,\"state\":\"idle\"}" }"#])
                XCTAssertNil(result)
                do {
                    _ = try await RecordingClient(executable: invalid).run([])
                    XCTFail("无效可执行文件不能启动成功")
                } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
            } catch { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        task.cancel()
    }
}
