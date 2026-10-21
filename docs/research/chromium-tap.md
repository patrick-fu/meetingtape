# Chromium CoreAudio tap implementation essentials

Research for [issue #2](https://github.com/patrick-fu/meetingtape/issues/2), reviewed 2026-10-21. Chromium references are pinned to [`995e514c94f75e6cee5b97b7161f4b386b1f6af6`](https://github.com/chromium/chromium/commit/995e514c94f75e6cee5b97b7161f4b386b1f6af6). This is source research, not a successful capture experiment on every supported macOS version.

## Sources

- Chromium [`media/audio/mac/catap_audio_input_stream.mm`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm) and [its header](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.h): tap configuration, callback processing, lifecycle and device changes.
- Chromium [`catap_api.mm`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_api.mm): thin wrappers around HAL functions; [`catap_audio_input_stream_unittest.mm`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream_unittest.mm): mocked regression coverage, not hardware validation.
- Chromium [`audio_manager_mac.cc`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/audio_manager_mac.cc), [`audio_loopback_input_mac.h`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/audio_loopback_input_mac.h), [`audio_features.cc`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/audio_features.cc) and [`media_switches.cc`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/base/media_switches.cc): routing, defaults and feature gates.
- Apple: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [`AudioHardwareCreateProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)), [`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription), [`isExclusive`](https://developer.apple.com/documentation/coreaudio/catapdescription/isexclusive), [`muteBehavior`](https://developer.apple.com/documentation/coreaudio/catapdescription/mutebehavior), [`kAudioTapPropertyFormat`](https://developer.apple.com/documentation/coreaudio/kaudiotappropertyformat) and [`kAudioAggregateDeviceTapAutoStartKey`](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetapautostartkey).
- Apple SDK headers inspected locally: **macOS 26.2**, under `$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers/`. Relevant locations: `AudioHardwareTapping.h:33–54`; `CATapDescription.h:19–34,49–111,125–186`; `AudioHardware.h:586–604,657–680,1360–1436,1560–1645,1861–1900,2006–2027`. Header line references below refer to this SDK. The newer SDK's declarations do not imply that newer-only properties are available on macOS 14.2.

## Findings

### 1. API surface and construction recipe

**The requested filename is the wrong implementation to copy.** At the pinned revision, `media/audio/mac/audio_loopback_input_mac_impl.mm` implements `SCKAudioInputStream`; the CoreAudio path is `CatapAudioInputStream` / `CatapAudioInputStreamSource` in `catap_audio_input_stream.{h,mm}`. `AudioManagerMac` selects the tap factory separately from SCK ([`audio_manager_mac.cc:910–922`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/audio_manager_mac.cc#L910-L922)). Do not carry the SCK class's permission or sample-layout assumptions into the tap path.

There are two independent choices:

| Choice | Chromium / Apple meaning |
| --- | --- |
| Global process selection | `initStereoGlobalTapButExcludeProcesses:`; `processes` is an exclusion list and `isExclusive == true`. Empty exclusions capture all eligible processes. |
| Per-application selection | `initStereoMixdownOfProcesses:`; `processes` is an inclusion list and `isExclusive == false`. Values are **CoreAudio process object IDs**, not PIDs. |
| Default output routing | Set `deviceUID` to the current default output UID and `stream` to `0`. This scopes the mix to that device's first output stream. |
| All output routing | Leave `deviceUID` and `stream` unset. A global tap then covers outputs across devices; Chromium also uses this routing for per-application capture. |

Apple defines `exclusive` as inversion of the process list; it is unrelated to exclusive ownership of an audio device (`CATapDescription.h:125–148`). Chromium tests explicitly check both list directions and the all-device configuration ([`catap_audio_input_stream_unittest.mm:732–845`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream_unittest.mm#L732-L845), [`1018–1029`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream_unittest.mm#L1018-L1029)). An empty **inclusion** list does not mean capture everything. For application capture, Chromium watches process-object-list changes and updates the active description as audio objects appear or disappear ([`catap_audio_input_stream.mm:1485–1510`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1485-L1510)).

`muteBehavior` affects local playback, not the captured samples (`CATapDescription.h:19–34`):

| Value | Local playback |
| --- | --- |
| `CATapUnmuted` | Continues during capture; default behavior. |
| `CATapMuted` | Tapped process audio is withheld from hardware. |
| `CATapMutedWhenTapped` | Playback is withheld while another client reads the tap. |

Normal Chromium capture retains the unmuted default; only its explicit mute variants set `CATapMuted`. It names the tap and sets `privateTap` to true. Meeting recording should explicitly choose unmuted behavior so participants remain audible. Tap privacy and aggregate privacy are separate settings (`CATapDescription.h:156–173`; [`catap_audio_input_stream_unittest.mm:603–614,1007–1015`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream_unittest.mm#L603-L614)).

The HAL recipe is:

1. Create the description and call `AudioHardwareCreateProcessTap`; retain the returned tap `AudioObjectID`. Reject both an error status and `kAudioObjectUnknown`.
2. Create a **private aggregate containing the tap**, using a fresh aggregate UID. Its tap-list entry identifies the tap by UUID string (`description.UUID.UUIDString` in Chromium), with drift compensation enabled.
3. Set the aggregate's nominal sample rate and buffer frame size; register its IOProc; start the aggregate with that IOProc ID.

Chromium's creation dictionary is exactly this combination of keys, without a hardware subdevice list, main subdevice or clock-device key:

| Key | Value |
| --- | --- |
| `kAudioAggregateDeviceNameKey` | Diagnostic name |
| `kAudioAggregateDeviceUIDKey` | Fresh UUID string |
| `kAudioAggregateDeviceIsPrivateKey` | `true` |
| `kAudioAggregateDeviceTapListKey` | One dictionary containing `kAudioSubTapUIDKey` and `kAudioSubTapDriftCompensationKey = true` |
| `kAudioAggregateDeviceTapAutoStartKey` | `false` |

Apple documents tap/aggregate construction and UID lookup in its [sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps); the dictionary keys are defined in `AudioHardware.h:1560–1645,1861–1900`. Chromium's concrete construction is [`catap_audio_input_stream.mm:805–865`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L805-L865). The aggregate does not need to combine the microphone: MeetingTape's microphone remains a separate AVAudioEngine input.

The IOProc is registered with `AudioDeviceCreateIOProcID`, then activated with `AudioDeviceStart`. HAL invokes it with an input `AudioBufferList` and `AudioTimeStamp`; this is callback-driven capture, not polling or an `AudioUnitRender` loop. Chromium processes the first non-null buffer and expects a single stream ([`catap_audio_input_stream.mm:177–198`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L177-L198)). Apple also exposes a block-based registration API; its queue dispatch is synchronous (`AudioHardware.h:1383–1404`).

### 2. Minimum system version and permission facts

**The process-tap API requires macOS 14.2.** `AudioHardwareTapping.h:43–54`, Apple's [function documentation](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)) and Chromium's gate in [`media_switches.cc:2013–2015`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/base/media_switches.cc#L2013-L2015) agree. Earlier availability on the description class does not make capture work on an earlier OS. Avoid `bundleIDs` and `processRestoreEnabled`, which the inspected SDK marks macOS 26.0-only.

Apple requires `NSAudioCaptureUsageDescription` and describes a system-audio recording prompt on first recording from an aggregate containing a tap. Chromium identifies `AudioDeviceCreateIOProcID` as the prompt-triggering operation, and probes permission by reading and writing back `kAudioTapPropertyDescription`; probe failure becomes `kFailedSystemPermissions` ([`catap_audio_input_stream.mm:867–905`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L867-L905), [`1378–1401`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1378-L1401)). These are observed implementation/documentation facts; terminal identity, TCC attribution, signing and distribution requirements belong to [issue #3](https://github.com/patrick-fu/meetingtape/issues/3).

### 3. Format, fixed-rate output and idle behavior

Chromium requests **stereo, 48,000 Hz, 960 frames (20 ms)** as its consumer format ([`audio_loopback_input_mac.h:13–23`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/audio_loopback_input_mac.h#L13-L23), [`audio_manager_mac.cc:694–706`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/audio_manager_mac.cc#L694-L706)). Its tap callback consumes **interleaved float32**, then deinterleaves into Chromium's audio buses. SCK's planar float32 layout does not apply here. The callback rejects unexpected channel counts or frame counts, which may briefly occur during Bluetooth profile changes ([`catap_audio_input_stream.mm:1091–1176`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1091-L1176)).

For a new implementation, inspect `kAudioTapPropertyFormat` and the aggregate input stream ASBD before interpreting buffers: Apple defines the former as the tap's current format accessible through an aggregate (`AudioHardware.h:2018–2021`). There is no sample-rate or float32 property on `CATapDescription` itself. Set the aggregate's `kAudioDevicePropertyNominalSampleRate` and `kAudioDevicePropertyBufferFrameSize`, check statuses, and verify the delivered format. A fixed engine format is a conversion contract, not a consequence of choosing the stereo initializer.

Chromium explicitly works around **macOS 14 sample-rate mismatch handling**. In default-device capture it reads the device's virtual-format rate, runs the aggregate at that rate, and uses `ConvertingAudioFifo` when it differs from the consumer rate. A 44.1 kHz device yields nominal 882-frame input blocks for 960-frame / 48 kHz output blocks. macOS 15+ normally uses HAL's resampler; internal conversion can still be forced. The test fixture exercises that 44.1-to-48 kHz path ([`catap_audio_input_stream_unittest.mm:1593–1636`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream_unittest.mm#L1593-L1636)). **This fallback is selected only in default-device mode**; it does not establish reliable all-device format conversion on Sonoma ([`catap_audio_input_stream.mm:167–174,1583–1616`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1583-L1616)).

For mono Bluetooth/HFP devices, Chromium can force mono tap capture and duplicate it when the consumer expects stereo. This avoids relying on a failing OS mono-to-stereo path. MeetingTape should accept changing hardware formats and normalize outside the HAL callback rather than assuming every device is stereo.

**Idle is not EOF.** In the inspected SDK, a true `kAudioAggregateDeviceTapAutoStartKey` makes aggregate start wait for a tap to receive audio; Chromium sets it false. Neither that setting nor `isExclusive` is a silence-suppression control. The inspected callback forwards valid zero samples without filtering them, but ignores null input data and does not synthesize missing blocks. These sources do not guarantee continuous callbacks during silence on every device/OS. Measure idle-start, silent gaps and return-to-audio; do not compress the file timeline by merely concatenating whichever callbacks arrive.

### 4. Lifecycle, failures and device boundaries

The intended acquisition/release order is:

```text
create tap → create aggregate → configure → create IOProc → install listeners → start
stop delivery / detach callback target → remove listeners → stop aggregate
→ destroy IOProc → destroy aggregate → destroy tap → release description / callback context
```

Chromium retains each successfully acquired handle, so a later open failure is unwound when its wrapper destroys the source. Startup failure is reported to the consumer. Apple warns aggregate destruction can complete asynchronously (`AudioHardware.h:670–680`); do not equate the destroy call returning with all callbacks having disappeared.

The recent implementation fences the callback through `CatapIoProcProxy`: `Detach()` waits for an in-flight invocation and clears the source pointer. When `AudioDeviceStop` or IOProc destruction fails, it deliberately retains the detached proxy so a late OS callback cannot access freed memory. Mocked tests call the saved IOProc after teardown for both failure cases ([`catap_audio_input_stream_unittest.mm:1492–1578`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream_unittest.mm#L1492-L1578)). A Swift `Unmanaged` pointer must have an equally explicit lifetime; releasing it on the assumption that stop always succeeds is unsafe.

CoreAudio property listeners run on a private serial queue and marshal changes onto the owner's sequence, avoiding teardown from a HAL notification context. The stream monitors aggregate liveness and sample rate; default-device capture additionally watches default-output changes and, on the Sonoma conversion path, the physical device's rate. Default-device/rate changes rebuild a fresh source and restart it if it was running. Reopen failure becomes a runtime error; aggregate death also signals an error. The restart feature is enabled by default ([`audio_features.cc:74–88`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/audio_features.cc#L74-L88)). This is rebuild-based recovery, not proof of gapless switching.

Two source-specific cautions:

- An unanswered permission dialog can block IOProc creation for about 60 seconds. Chromium has a **disabled-by-default** feature that terminates its audio-service process after this timeout; a standalone CLI must choose its own failure/retry behavior instead of blindly copying the process-exit policy.
- `Stop()` detaches the source's proxy and removes listeners; `Start()` does not reattach them. Chromium's device-change recovery creates a new source. Do not assume same-source stop/start is supported merely because a header comment says restart is possible. MeetingTape's no-pause/resume scope avoids needing that contract.

### 5. Chromium file and line map

All links use the pinned revision; line numbers are from the unmodified raw files.

| Concern | Location |
| --- | --- |
| Public source/stream contracts and owned handles | [`catap_audio_input_stream.h:51–105,153–166,284–303,306–328`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.h#L51-L105) |
| Callback lifetime fence and IOProc | [`catap_audio_input_stream.mm:59–87,177–198`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L59-L87) |
| Property listener queue / registration / removal | [`catap_audio_input_stream.mm:474–604`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L474-L604) |
| Rate-aware buffer sizes and converter setup | [`catap_audio_input_stream.mm:610–682`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L610-L682) |
| Description, tap, aggregate and open error paths | [`catap_audio_input_stream.mm:727–919`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L727-L919) |
| Start, stop, reverse-order teardown | [`catap_audio_input_stream.mm:922–1068`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L922-L1068) |
| Timestamp fallback, buffer checks and conversion | [`catap_audio_input_stream.mm:1071–1181`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1071-L1181) |
| Rate/frame-size setters and permission probe | [`catap_audio_input_stream.mm:1324–1401`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1324-L1401) |
| Liveness, rate, route and application changes | [`catap_audio_input_stream.mm:1404–1513`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1404-L1513) |
| Wrapper format selection and rebuilding | [`catap_audio_input_stream.mm:1575–1628,1686–1752`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1575-L1628) |
| Actual HAL calls | [`catap_api.mm:15–112`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_api.mm#L15-L112) |

### 6. Timing and processing boundaries

Use the callback's valid `mHostTime` as the capture time, not the wall-clock time when an encoder eventually receives the block. Chromium falls back to an expected next timestamp when host time is missing. When conversion buffers input, it subtracts the queued-input duration before timestamping output; that buffered duration matters for alignment ([`catap_audio_input_stream.mm:1071–1181`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1071-L1181)).

The tap path does not implement MeetingTape's microphone 3A. In particular, its `SetOutputDeviceForAec` is empty. The stream's `kMaxVolume = 0.0` denotes unsupported volume control; callback samples are not multiplied by zero ([`catap_audio_input_stream.mm:606–608,1665–1683`](https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1665-L1683)). Keep captured system samples and their timestamps available both to the recording pipeline and to the chosen microphone AEC implementation.

## Implications for MeetingTape

Implement a small SwiftPM engine-owned tap source using `CoreAudio` and `Foundation`, available on macOS 14.2+. Keep the thin CLI responsible for orchestration and exit reporting. Apple's [Swift initializer](https://developer.apple.com/documentation/coreaudio/catapdescription/init(stereoglobaltapbutexcludeprocesses:)) and [Swift sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) show direct access; adopting Chromium's Objective-C++ implementation is unnecessary.

Use an unmuted private tap plus private aggregate, explicit handle ownership, a stable IOProc context and serialized lifecycle control. Copy samples into bounded, preallocated engine buffers before leaving HAL's callback; perform encoding and cross-stream assembly off that callback. Expose actual format, host timestamps and discontinuities to the engine. Choose a canonical float32 engine rate (48 kHz is a reasonable candidate), verify actual device formats, and support application-side conversion for Sonoma.

Keep mic capture in AVAudioEngine. Align system and mic on a shared host-time timeline, feed the captured system reference to mic 3A, and assemble the agreed single stereo m4a with system on the left and processed mic on the right. Tap drift compensation does not by itself synchronize a separately running AVAudioEngine. Define silence insertion and recovery gaps at the assembler so a quiet system channel does not shorten the recording.

These are implementation implications, not additional settled product decisions. Route selection, mono folding, the fixed output rate and hot-switch policy still require explicit choices or validation below.

## Open questions

1. **System capture scope:** follow the default output, or capture across all outputs? Both use global process selection. Chromium's default is the former; MeetingTape must avoid silently treating them as equivalent. Verify per-app routing and additional device streams when selecting scope.
2. **One left channel:** how should stereo/multichannel system audio fold to mono while retaining the agreed meaning of “raw” (no 3A)? Taking only the source's left channel can lose audio. Decide whether to retain stereo for the AEC reference before folding for the file.
3. **Format matrix:** validate 44.1/48/96 kHz devices, mono HFP transitions, macOS 14.2/14.x versus 15+, and especially all-output capture on Sonoma. Confirm actual ASBD, delivered frame sizes and channel counts rather than relying on successful setters.
4. **Idle and recovery:** measure capture started while nothing plays, extended silence, app start/exit, output unplug, Bluetooth A2DP/HFP changes, sleep/wake and default-output switches. Confirm file duration, gap handling and AEC-reference continuity. No hardware experiment in this ticket establishes these outcomes.
5. **Failure contract:** choose observable behavior for permission denial/timeouts, aggregate death, failed rebuild and failed stop/IOProc destruction. Preserve callback-context safety even if cleanup reports an error; use issue #3's permission/deployment findings for CLI packaging.
6. **AEC alignment:** measure tap-to-mic delay and long-session drift with the selected 3A engine. Neither Chromium's tap wrapper nor the private aggregate supplies the required complete AEC integration.

Verification scope: inspected the pinned raw source files and checked their Git blob hashes against GitHub metadata; cross-checked relevant declarations in the installed Apple SDK. Chromium tests were read, not executed. No capture, permission prompt, device-switch or recording-output experiment was run for this documentation ticket.
