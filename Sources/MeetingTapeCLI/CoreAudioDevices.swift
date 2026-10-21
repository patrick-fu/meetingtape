import CoreAudio

/// Minimal read-only CoreAudio device enumeration used by doctor.
enum CoreAudioDevices {
    /// Counts devices with at least one stream in each scope.
    /// Returns nil when CoreAudio cannot be queried.
    static func deviceCounts() -> (inputs: Int, outputs: Int)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0
        else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceIDs) == noErr
        else { return nil }

        var inputs = 0
        var outputs = 0
        for device in deviceIDs {
            if streamCount(of: device, scope: kAudioObjectPropertyScopeInput) > 0 { inputs += 1 }
            if streamCount(of: device, scope: kAudioObjectPropertyScopeOutput) > 0 { outputs += 1 }
        }
        return (inputs, outputs)
    }

    private static func streamCount(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return size / UInt32(MemoryLayout<AudioStreamID>.size)
    }
}
