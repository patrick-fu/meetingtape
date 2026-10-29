import Darwin
import Foundation

@main struct RecoveryFixture {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: path)
        var snapshot = SessionSnapshot(sessionID: "verification", recoveryPath: path)
        snapshot.state = .recording
        let store = try RecoveryStore(directory: directory, keepRaw: true, snapshot: snapshot)
        func append(at frame: Int64) throws {
            var stereo: [Float] = []
            var microphone: [Float] = []
            for index in 0..<48_000 {
                let time = Double(index) / 48_000
                stereo.append(Float(0.15 * sin(2 * .pi * 440 * time)))
                stereo.append(Float(0.12 * sin(2 * .pi * 880 * time)))
                microphone.append(Float(0.2 * sin(2 * .pi * 330 * time)))
            }
            try store.append(stereo: stereo, rawMicrophone: microphone, at: frame)
        }
        try append(at: 0)
        try append(at: 144_000)
        snapshot.elapsedSeconds = 5
        try store.checkpoint(snapshot)
        try append(at: 240_000)
        let descriptor = open(directory.appendingPathComponent("audio.caf").path, O_RDONLY)
        guard descriptor >= 0, fsync(descriptor) == 0 else { fatalError("fixture synchronization failed") }
        close(descriptor)
        FileHandle.standardOutput.write(Data("READY\n".utf8))
        while true { sleep(1) }
    }
}
