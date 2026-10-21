# TCC permissions and ownership for MeetingTape

Research for [issue #3](https://github.com/patrick-fu/meetingtape/issues/3), collected on 2026-10-21. Input to [issue #5: signing and distribution](https://github.com/patrick-fu/meetingtape/issues/5). This documents the settled CoreAudio-tap + AVAudioEngine architecture; it does not choose a distribution or helper architecture.

**Result:** process taps require system-audio authorization (`AudioCapture`); microphone capture separately requires `Microphone`. Screen Recording is not an additional requirement of the tap path. Permission ownership depends on TCC's responsible-code attribution as well as code identity. A stable bundle identifier alone cannot preserve grants across changed ad-hoc builds or guarantee ownership by a CLI.

Evidence here is documentation, pinned upstream source, and read-only local metadata. No recording, permission request, reset, cron installation, or TCC database modification was performed. In particular, the complete first-run/upgrade behavior of a MeetingTape binary has not been tested on macOS 14, 15, or 26.

## Sources

- **S1 — Apple public tap contract:** [Capturing system audio with Core Audio taps][S1], [NSAudioCaptureUsageDescription][S1a], and [AudioHardwareCreateProcessTap][S1b]. The sample's current page metadata says macOS/Xcode 26, but its setup text says macOS 14.2 or later. The installed macOS 26.2 SDK's `CoreAudio.framework/Headers/AudioHardwareTapping.h:34–54` independently marks the create/destroy functions `API_AVAILABLE(macos(14.2))`.
- **S2 — Apple public permission operations:** [Resetting access to protected resources in macOS][S2] lists `AudioCapture`, `Microphone`, and `ScreenCapture` separately, including the corresponding usage-description keys. [Requesting authorization for media capture on macOS][S2a] documents microphone status, requests, denial, and missing usage strings.
- **S3 — Apple system-audio answer:** [Apple engineer reply, January 2025][S3], confirms that starting recording from a tap-containing aggregate triggers system-audio permission. The later silence/status-query comment in that thread is from a community participant, not Apple.
- **S4 — Apple settings, version-selected:** [Sonoma 14][S4a], [Sequoia 15][S4b], and [Tahoe 26][S4c] guides describe the Screen & System Audio Recording pane and distinguish audio-only access from screen-and-audio access. These guides are not patch-by-patch runtime tests.
- **S5 — Apple identity mechanism:** [TN3127: Inside Code Signing: Requirements][S5] explains designated requirements (DRs), TCC's microphone identity check, ad-hoc instability, and differences between development and distribution DRs. [DTS answer about ad-hoc update reauthorization, August 2025][S5a] applies this directly to Screen Recording.
- **S6 — Apple responsibility mechanism:** [DTS: command-line tools and responsible code, June 2024][S6], [DTS: embedding a tool's Info.plist, January 2022][S6a], and [DTS: command-line helpers, June 2023][S6b]. The first discussion is about Full Disk Access; its launch-context examples are architectural guidance, not a measured AudioCapture/Microphone matrix.
- **S7 — Apple identity/path and signing references:** [PPPC payload settings][S7] documents bundle-ID or file-path matching plus a code-signing requirement. [Code Signing Tasks][S7a], an archived guide, documents embedding an Info.plist in a single-file tool and self-signed certificates for development. It advises against shipping self-signed apps. These sources do not specify the complete internal TCC database schema.
- **S8 — Chromium, pinned at `995e514c94f75e6cee5b97b7161f4b386b1f6af6`:** [CATap stream, lines 867–905][S8a], [permission probe, lines 1378–1401][S8b], [CoreAudio wrappers][S8c], and [localized usage-description generation][S8d]. [Commit `4d26c694`][S8e] explicitly explains why Chromium added `NSAudioCaptureUsageDescription` for CoreAudio taps.
- **S9 — jftuga/mac-audio-recorder, pinned at `06c38d0c3d5279fad2c86202521d4ae60a74480a`:** [README][S9a], [Package.swift][S9b], [Makefile][S9c], [Info.plist][S9d], and [PermissionChecker.swift][S9e]. This is the author's implementation/report of **ScreenCaptureKit**, not a CoreAudio-tap permission contract. The README reports development/testing on macOS 26.5 and requires macOS 15+.
- **S10 — AudioCap implementation, pinned at `6f609e8ad1b1e11fa0e8edbe91864cb099f00de3`:** [AudioRecordingPermission.swift][S10] passes `kTCCServiceAudioCapture` to dynamically loaded private TCC preflight/request functions behind `ENABLE_TCC_SPI`. This is evidence of an implementation detail, not public API guidance.
- **S11 — Local Apple and Doubao artifacts:** read-only inspection on macOS **26.6.2 (25G83)**. Apple's `TCC.framework/Versions/A/Resources/Localizable.loctable` contains distinct request-message keys for `kTCCServiceAudioCapture`, `kTCCServiceMicrophone`, and `kTCCServiceScreenCapture`. `/Applications/Doubao.app` version **2.32.6** was inspected with `plistlib` and `codesign`; `codesign --verify --strict --verbose=2` passed. Local artifacts are version-bound observations, not published compatibility promises. Reproduction details appear in finding 5.

## Findings

### 1. Which permissions does a process tap need?

| Capture path | Required capability / TCC service | Usage description | Consequence for MeetingTape |
| --- | --- | --- | --- |
| CoreAudio process/system-output tap | System-audio capture / `AudioCapture` | `NSAudioCaptureUsageDescription` | Expect interactive system-audio consent. |
| AVAudioEngine microphone input | Microphone / `Microphone` | `NSMicrophoneUsageDescription` | Obtain microphone consent separately. |
| Screen/content capture | Screen Recording / `ScreenCapture` | Depends on the capture API | Not needed merely to use a CoreAudio tap. |

Apple explicitly associates system audio with `AudioCapture` in its public reset-service list, and associates the usage key with taps. The `kTCCService…` spellings are private implementation names, corroborated by Apple's installed resources and AudioCap; they should not become product API dependencies. Public `tccutil` uses the unprefixed service names. [S1], [S1a], [S2], [S10]

A tap is not an authorization bypass. Apple's sample and engineer reply place the prompt at the start of recording through an aggregate containing a tap. Chromium identifies `AudioDeviceCreateIOProcID` as the concrete first-use prompt point in its implementation. Successful `AudioHardwareCreateProcessTap` alone therefore does not demonstrate permission or usable audio. A tap being private describes its visibility, not exemption from consent. [S1], [S3], [S8a]

The Settings pane groups screen and system-audio controls, while allowing audio-only access. Its combined name does not imply that MeetingTape must request display access. Conversely, a preexisting broader grant is not evidence that taps have no permission gate; whether it satisfies an audio-only request should be measured per OS. [S4a], [S4b], [S4c]

| OS scope | What the evidence establishes | What remains unverified |
| --- | --- | --- |
| macOS 14.2–14.x | API and usage key availability begin at 14.2; Apple's sample setup says 14.2+. Sonoma's guide describes audio-only permission. | Clean-install behavior on 14.2 versus later 14.x patches; no historical 14.2 machine was exercised. A third-party project requiring 14.4 does not redefine Apple's API availability. |
| macOS 15 | Apple's January 2025 answer confirms the tap prompt; the Sequoia guide separates audio-only from screen+audio. | Exact CLI owner, prompt wording, denial/error behavior, and reset behavior for each 15.x patch. |
| macOS 26 | Current Apple sample documents the same gate. Local 26.6.2 TCC resources retain all three distinct services. | No fresh tap or microphone request was performed, so local metadata is not proof of a successful recording or of every 26.x release. |

No retrieved primary source establishes a permission-free 14.2 mode or a switch from AudioCapture to ScreenCapture on 15/26. Do not claim an exhaustive runtime compatibility matrix from these sources.

Entitlements are a separate layer. Apple's Hardened Runtime **Audio Input** entitlement, `com.apple.security.device.audio-input`, covers microphone/CoreAudio input access; App Sandbox's microphone entitlement is `com.apple.security.device.microphone`. Neither replaces TCC consent. The release's chosen runtime/sandbox configuration needs its own check. [Audio Input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input), [Sandbox microphone entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone)

### 2. What identity owns a grant?

Three questions must be kept separate:

1. **Responsibility:** which app or item of code does TCC attribute this action to? Apple says the attribution algorithm is undocumented and has changed. It is not simply the immediate parent PID.
2. **Identity continuity:** does the current executable satisfy the recorded owner's DR? A signing identifier usually aligns with the bundle identifier, while the signer/certificate conditions establish who may use that identifier. A matching identifier string alone is insufficient.
3. **Lookup/location:** Apple supports both bundle-ID and executable-path identities in PPPC policy, with an accompanying code requirement. An unbundled tool can therefore have meaningful identity without being a `.app`, but moving it or changing a Homebrew Cellar target cannot be assumed irrelevant. This is not a promise about every service's internal lookup rules. [S5], [S6], [S7]

For a single-file CLI, embed metadata in Mach-O's `__TEXT,__info_plist` section. Apple's archived guide calls for at least `CFBundleIdentifier` and `CFBundleName`; MeetingTape also needs both capture-purpose strings. Keep the code-signing identifier aligned with the chosen bundle identifier. SwiftPM can pass `-sectcreate __TEXT __info_plist <plist>` through linker settings, as audiorec does. A loose plist next to an executable does not supply that embedded section. [S6a], [S7a], [S9b]

A plain CLI with no embedded plist may execute under a terminal's identity, but that is not a standalone permission strategy. When a capture request is attributed to code that lacks its required microphone usage string, Apple documents termination. Adding the strings avoids missing-purpose metadata; it does not instruct TCC to ignore the launching application. [S2a], [S6]

| Launch context | Apple guidance / bounded inference |
| --- | --- |
| User runs a tool from Terminal | DTS's responsible-code example names **Terminal**. Treat host ownership as the baseline to test, not a measured guarantee for both audio services on every OS. |
| Another GUI app spawns a helper | DTS names the app as responsible. For an agent's app → shell → CLI chain, the agent app may be the relevant owner; an agent CLI running inside Terminal may instead trace back to the terminal. No Codex-specific attribution was measured here. |
| Xcode/debugger | DTS describes launch machinery that can deliberately break the usual responsibility chain. An Xcode grant is not evidence that a Terminal or agent invocation will work. |
| `launchd` agent/daemon | DTS recommends `SMAppService`, or `AssociatedBundleIdentifiers` for a legacy launchd plist. `launchd` itself is not automatically the owner. |
| `cron` or other unattended launcher | It does not inherit an interactive terminal's permission simply because the same executable path is used. No primary audio-specific cron ownership guarantee was found. Verify the actual responsible code and GUI-session availability; initial user consent cannot be assumed available headlessly. |

These examples derive from Apple's general TCC guidance, chiefly an FDA discussion. They justify testing the launch chain; they do **not** settle an untested audio-specific row. Double-forking or detaching a helper to manipulate attribution is particularly fragile: DTS explicitly says it breaks responsibility heuristics. [S6], [S6b]

**Conflict with audiorec's README:** its final limitation claims that explicit signing plus an embedded bundle identifier attaches grants to the tool instead of the terminal. Its `Package.swift` actually embeds the plist even for bare `swift build`; `make` additionally strips, signs with `--identifier com.jftuga.audiorec`, and verifies metadata. These facts establish its packaging, not a cross-host TCC guarantee. Preserve the author's attribution claim as an unreplicated report; Apple's launch-dependent responsibility model prevents promoting it into MeetingTape's contract. [S9a], [S9b], [S9c], [S6]

#### Reset and reauthorize the actual owner

Use **System Settings → Privacy & Security → Microphone** and **Screen & System Audio Recording**, selecting audio-only access for the latter when offered. Inspect the name actually shown; it may be the host or the tool. Enable the appropriate entry after a denial, and quit/reopen the recorder or host if macOS requests it. Restart a failed capture process before retrying. [S2a], [S4c]

For a deliberate onboarding test, Apple's documented bundle-scoped reset pattern is:

```sh
# Set this to the owner established by observation, not an assumed CLI identifier.
TCC_OWNER_BUNDLE_ID='com.example.actual-owner'
tccutil reset Microphone "$TCC_OWNER_BUNDLE_ID"
tccutil reset AudioCapture "$TCC_OWNER_BUNDLE_ID"
```

These illustrative commands were **not run**. Reset removes a decision; it does not grant access. Relaunch through the same intended host and invoke the protected capture path to prompt again. For a tap, creating the object alone may not reach the prompt. `tccutil` documents a bundle-ID argument, not a scoped executable-path argument; if a bare tool has a path-based record, do not promise this bundle-scoped recipe resolves it. Establish the record/Settings behavior during validation. Avoid a service-wide reset of other apps merely to repair MeetingTape. [S1], [S2], [S8a]

### 3. Why do changed ad-hoc builds lose grants?

Apple describes TCC recording a DR and requiring a later version to satisfy it. Unsigned code has no DR; ad-hoc code has one tied to a particular build. Changed signed content changes the code-directory hash (CDHash), so a build-specific ad-hoc identity cannot establish that a changed version is the same authorized code. Keeping the path, filename, or `CFBundleIdentifier` unchanged does not repair this. Apple's DTS answer explicitly confirms the resulting update/Screen Recording problem. [S5], [S5a]

This corroborates audiorec's warning that released ad-hoc binaries require Screen Recording approval after `brew upgrade`. Its ScreenCaptureKit permission is different from MeetingTape's AudioCapture gate, but the identity-continuity mechanism applies. Strictly, a bit-identical rebuild need not produce a new hash; the problem is changed code/metadata, not the mere act of running a build command. Attribution to an already-authorized host can also hide the CLI's identity change, so repeated prompts are not guaranteed in every launch context. [S9a], [S5], [S6]

| Signing option | Appropriate use and limits |
| --- | --- |
| Apple Development | Apple's recommended development identity. Stable identity/identifier can preserve grants across changed local builds. Development and Developer ID DRs can differ, so a release build may legitimately require its own initial grant. |
| Developer ID Application | Apple's recommended direct-distribution identity. Preserve the signing identifier, compatible DR, and release signature across upgrades. Notarization/Gatekeeper acceptance and user TCC consent remain separate concerns. |
| Stable self-signed code-signing identity | A local development option when the same certificate/private key and identifier are reused. Apple documents self-signed certificates as sufficient for DR validation, but advises against shipping them. Regenerating a certificate with the same display name is not identity continuity. Verify old/new requirements rather than assuming compatibility. |
| Ad-hoc / unsigned | Useful for disposable builds; cannot promise grant continuity when the authorized code changes. Not the default recommendation for a distributed recorder whose upgrades should retain grants. |

The identity rules come from TN3127 and Apple's code-signing guide; none of these signatures grants microphone or system-audio access by itself. [S5], [S5a], [S7a]

### 4. What does this mean for v1 development and Homebrew?

- **Development:** include both purpose strings and a deliberate signing identifier from the start. Use a stable development identity when repeatable onboarding matters. Run the first permission flow in a local logged-in GUI session through each supported caller. A grant obtained in Xcode or Terminal is not sufficient acceptance evidence for an agent invocation. [S1], [S2a], [S5], [S6]
- **Capture readiness:** treat the two permissions independently. Public AVFoundation APIs expose microphone status/request. The retrieved public tap API/header documentation supplies an operational prompt, not an equivalent standalone system-audio preflight API. Do not use `CGPreflightScreenCaptureAccess()` as an AudioCapture status oracle or copy AudioCap's private TCC SPI into the production CLI. [S1], [S2a], [S10]
- **Failure handling:** a created tap, a completed prompt, or all-zero buffers alone are insufficient proof of readiness. Chromium adds a property probe to identify a likely permission failure, but that is its implementation technique, not Apple's formal authorization-status API. Validate actual samples under a controlled audible test, and distinguish denial, no source audio, device failure, and timeout. [S8a], [S8b]
- **Homebrew:** installation is not consent. Decide whether brew installs an upstream signed artifact or builds/signs locally, then inspect what the consumer actually executes. Compare the installed old/new DRs, purpose strings, resolved paths, and signatures after an upgrade. Do not assume a stable `/opt/homebrew/bin` symlink proves stable TCC ownership or that an upstream signature survives every packaging operation. This is a release-validation recommendation, not an assertion about all brew formulae.
- **Future GUI:** an app or helper with intentional responsibility could give a clearer permission owner. A bundled helper is an option for #5 to evaluate against the CLI-first requirement, not a decision made by this research. A different helper/bundle identifier may have its own grant. [S6], [S6a], [S6b]

### 5. What do Chromium and Doubao actually demonstrate?

**Chromium:** the current tap implementation is `media/audio/mac/catap_audio_input_stream.mm`, not the older `audio_loopback_input_mac_impl.mm` ScreenCaptureKit implementation. Its wrapper calls the public CoreAudio tap/aggregate/IOProc APIs. The first IOProc registration can display the permission dialog. Its comment reports a roughly 60-second unanswered-dialog timeout after which its audio process's CoreAudio operations fail; feature-controlled recovery terminates/restarts that audio process. This is a Chromium-observed failure mode, not an Apple guarantee for every OS or a reason for a standalone CLI to kill its host. [S8a], [S8c]

After registration Chromium reads the tap's `kAudioTapPropertyDescription` and writes the same description back. A failed probe returns `kFailedSystemPermissions`. It also supplies `NSAudioCaptureUsageDescription` in generated localized InfoPlist strings; the historical addition explicitly links it to CoreAudio taps. These inspected files do not implement a public TCC preflight function, and this evidence does not establish that a bare CLI inherits Chrome's bundled/multiprocess attribution. [S8b], [S8d], [S8e]

**Doubao local snapshot:** version 2.32.6 contains:

| Artifact | Observed fact |
| --- | --- |
| Main app Info.plist | `CFBundleIdentifier=com.bot.pc.doubao`; both system-audio and microphone usage-description keys; `NSPrincipalClass=BrowserCrApplication`. |
| Main app signature | Developer ID Application, Team ID `96L78H6LMH`; Hardened Runtime; `com.apple.security.device.audio-input=true`. DR requires its identifier, Apple Developer ID certificate conditions, and the same Team ID. Strict signature verification passed. |
| Nested `Contents/Helpers/Doubao Browser.app` | Separate bundle ID `com.bot.pc.doubao.browser`, version 2.32.6, also declaring both purpose strings and `BrowserCrApplication`. |
| Nested link router | Bundle ID `com.bot.pc.doubao.linkrouter`; version metadata `147.0.7727.149`, consistent with Chromium-derived packaging. |

This supports Doubao as a Chromium-derived, stably signed bundled reference with explicit audio-purpose metadata. It does **not** prove which identity owns its live TCC grants, which helper performs a particular recording, or which tap implementation is currently executing. No Doubao recording, TCC database inspection, or binary decompilation was performed. In particular, do not automatically use `com.bot.pc.doubao` when a live prompt might identify the separate browser bundle. [S11]

The local read-only inspection can be repeated with `sw_vers`, `plutil -p <bundle>/Contents/Info.plist`, `codesign -dvv -r- --entitlements - <bundle>`, and `codesign --verify --strict --verbose=2 <bundle>`. Apple's local service keys were read using Python `plistlib` from the TCC framework's `Localizable.loctable`. Receipts for this snapshot:

```text
macOS: 26.6.2 / 25G83
Doubao Info.plist SHA-256: 26beb501217716ec7de8a8a5177c36e91c175369c0452ef5391c2691d0f2c0b6
TCC Localizable.loctable SHA-256: 891af54bce3c798250044284124c27f43ba506a635358f3707551cf83897982f
```

## Implications for MeetingTape

Inputs to #5 are concrete: retain the two independent purpose strings; choose a stable signing identity/identifier and intended permission owner; decide how Homebrew preserves that identity; and document first authorization for the actual supported caller. Developer ID is Apple's direct-distribution recommendation. Stable signing is necessary for continuity when the recorder itself is the authorized code, but is not a substitute for validating responsibility. [S5], [S5a], [S6]

Before release, acceptance evidence should cover the **installed consumer binary**, rather than only an Xcode scheme:

| Dimension | Required evidence |
| --- | --- |
| OS | Record exact 14.x/15.x/26.x versions actually supported/tested; distinguish the 14.2 API floor from the chosen support floor. |
| Caller | Terminal and the actual coding-agent shell; cron only if explicitly supported. Record prompt/Settings owner and executable path for each audio service. |
| Consent state | Fresh, denied, allowed, and reset; system-only and microphone-only cases; capture known system audio plus known mic input and inspect the resulting channels. |
| Update | Same identity with changed code, changed ad-hoc code as a negative control, and a real brew upgrade with changing Cellar paths. Verify the existing grant against the resulting artifact. |
| Recovery | Ignored dialog/timeout and revoked permission. Confirm a bounded failure with actionable diagnostics rather than a purported successful silent recording. |

This matrix is future implementation/release work. It was not executed by this research ticket, and this document does not claim those paths passed.

## Open questions

1. Which identities actually own **each** audio grant for MeetingTape's chosen signing/package layout when launched through Terminal and the intended agent on 15/26? Apple does not publish enough detail to settle this without a controlled run. The audiorec README's stronger attribution claim remains unreplicated.
2. Does the eventual support floor remain 14.2, or require a later patch for runtime reliability? API availability alone cannot answer this. No historical clean-install test is included here.
3. Does an existing ScreenCapture grant satisfy the audio-only request consistently on supported patches, and how are duplicate/stale CLI entries displayed and reset? Test without requiring an unnecessary display grant.
4. Which public readiness/error signals are reliable on those versions? Chromium's property probe is useful evidence, but not a complete public TCC-status contract; missing permission and genuinely silent audio must remain distinguishable where possible.
5. Will the selected Homebrew packaging preserve a compatible DR and the intended owner across path changes? If stable self-signing is used for local development, verify the exact certificate/DR reuse and expect the Developer ID release to have a separate first grant when requirements differ.

[S1]: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
[S1a]: https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription
[S1b]: https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
[S2]: https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos
[S2a]: https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos
[S3]: https://developer.apple.com/forums/thread/771864
[S4a]: https://support.apple.com/guide/mac-help/mchld6aa7d23/14.0/mac/14.0
[S4b]: https://support.apple.com/guide/mac-help/mchld6aa7d23/15.0/mac/15.0
[S4c]: https://support.apple.com/guide/mac-help/mchld6aa7d23/26/mac/26
[S5]: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
[S5a]: https://developer.apple.com/forums/thread/795739
[S6]: https://developer.apple.com/forums/thread/756510
[S6a]: https://developer.apple.com/forums/thread/698337
[S6b]: https://developer.apple.com/forums/thread/732291
[S7]: https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web
[S7a]: https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html
[S8a]: https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L867-L905
[S8b]: https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_audio_input_stream.mm#L1378-L1401
[S8c]: https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/media/audio/mac/catap_api.mm
[S8d]: https://github.com/chromium/chromium/blob/995e514c94f75e6cee5b97b7161f4b386b1f6af6/chrome/tools/build/mac/infoplist_strings_util.cc#L188
[S8e]: https://github.com/chromium/chromium/commit/4d26c6941a81ce576732a4e43f84356ec0597adb
[S9a]: https://github.com/jftuga/mac-audio-recorder/blob/06c38d0c3d5279fad2c86202521d4ae60a74480a/README.md
[S9b]: https://github.com/jftuga/mac-audio-recorder/blob/06c38d0c3d5279fad2c86202521d4ae60a74480a/Package.swift#L26-L28
[S9c]: https://github.com/jftuga/mac-audio-recorder/blob/06c38d0c3d5279fad2c86202521d4ae60a74480a/Makefile#L11-L38
[S9d]: https://github.com/jftuga/mac-audio-recorder/blob/06c38d0c3d5279fad2c86202521d4ae60a74480a/Resources/Info.plist
[S9e]: https://github.com/jftuga/mac-audio-recorder/blob/06c38d0c3d5279fad2c86202521d4ae60a74480a/Sources/audiorec/Support/PermissionChecker.swift
[S10]: https://github.com/insidegui/AudioCap/blob/6f609e8ad1b1e11fa0e8edbe91864cb099f00de3/AudioCap/ProcessTap/AudioRecordingPermission.swift#L31-L73
[S11]: #sources
