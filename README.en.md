# MeetingTape

English | [简体中文](README.md)

A native meeting recorder and transcription app for Apple Silicon Macs. System audio and microphone input are preserved in separate stereo channels. A library organizes recordings and transcripts, while a compact floating window shows recording status and live bilingual captions. Transcribe saved recordings with local models or Doubao using your own key, and keep each version for comparison.

## Download & Installation

The latest pre-release is [v0.1.0-beta.1](https://github.com/patrick-fu/meetingtape/releases/tag/v0.1.0-beta.1), distributed as an Apple Developer ID-signed and notarized DMG.

- **Graphical App**: Download [MeetingTape-0.1.0-beta.1-arm64.dmg](https://github.com/patrick-fu/meetingtape/releases/download/v0.1.0-beta.1/MeetingTape-0.1.0-beta.1-arm64.dmg) and drag `MeetingTape.app` into `/Applications`. Grant Microphone and System Audio Recording permissions on first launch.
- **CLI Tool**: The DMG includes a standalone `CLI` folder. Copy the entire folder (keeping the binary and the sibling `Transcription` directory in the same path) to a persistent location and add it to your `PATH`. Verify with `meetingtape doctor`.

## Key Features

- **Dual-Channel Recording**: Captures a single `.m4a` stereo file with system audio on the left and microphone input on the right; voice processing degradation is logged. Channel separation does not guarantee physical isolation or elimination of speaker crosstalk.
- **Local & Cloud Transcription**: Run Qwen3 ASR and MOSS locally, or use Doubao File Transcription 2.0 with Bring Your Own Key (BYOK). Native recordings with a known channel layout default to separate-source recognition. Choose merged recognition in Settings to reduce resource use; external audio with an unknown layout defaults to merged.
- **Independent Version Comparison**: Each model's transcript is preserved separately. Compare text over matching time ranges and jump back to the audio in the app, without automatically merging versions.
- **Floating Window & Live Captions**: A compact window shows recording status and captions, with controls to expand or unpin it. Live transcription (Doubao cloud ASR) and caption translation (Apple local or Doubao text translation) have separate toggles. Original text and translation appear together, without spoken output.
- **Markdown Export**: The app and CLI share one exporter. Choose a primary transcript and optionally include other versions and measured timing, CPU, and process memory stats in collapsible sections. Disabled and disconnected intervals are marked; missing intervals are not automatically uploaded later.

## Usage & CLI

### GUI Workflow

Start recording from the menu bar or library window. The library window can be closed while background recording continues. The floating bar can be pinned, collapsed, or expanded; stopping auto-saves the recording to the library. Transcribe and export Markdown on demand.

Before transcribing, choose default models in Settings → 转写与模型 (Transcription & Models). Local models can be installed with one click using the recommended profile for your Mac. Configure Doubao credentials here; they are stored in macOS Keychain. Live transcription and caption translation are off by default and can be enabled separately.

### CLI Examples

`start`, `status`, and `stop` output plain text by default; add `--json` for structured JSON output.

```sh
# Verify environment and start recording (ensure output directory exists)
meetingtape doctor
mkdir -p ~/Documents/MeetingTape
meetingtape start --out ~/Documents/MeetingTape

# Check session status and stop
meetingtape status
meetingtape stop

# Install a local model (downloads pinned dependencies and weights on demand)
meetingtape transcribe install qwen --profile low-memory

# Replace this path with the recording file reported by stop
RECORDING="/absolute/path/to/saved-recording.m4a"
meetingtape transcribe start "$RECORDING" --models qwen

# Optional cloud alternative after configuring credentials; uploads audio
# meetingtape transcribe start "$RECORDING" --models doubao --allow-cloud

# Replace with the local task ID; check status, then export when complete
TASK_ID="replace-with-returned-task-id"
meetingtape transcribe status "$TASK_ID"
meetingtape transcribe export "$TASK_ID" --primary "$TASK_ID:qwen" --include-versions --output notes.md
```

## Requirements & Data Boundaries

- **System Requirements**:
  - Requires Apple Silicon (M-series chips).
  - Recording deployment target is macOS 14.2, but physical hardware testing on 14.2 is not yet verified.
  - Local transcription (Qwen3 ASR / MOSS) requires at least 16 GB unified memory (16–31 GB: low-memory profile; 32 GB+: standard profile).
  - Apple local subtitle text translation requires macOS 26 and downloaded system language packs.
- **Data & Network Boundaries**:
  - By default, audio files are stored locally in the chosen directory without automatic transcription or uploads.
  - Local models and dependencies require an internet connection to install. Once installed, they can transcribe saved recordings offline.
  - Live subtitle ASR currently supports only Doubao cloud and streams audio when enabled; Doubao text translation transmits text to the cloud. Both use BYOK configured in the Settings UI and bill your own account. Doubao live ASR combined with Apple local translation cannot be considered fully offline.

## Beta Status & Known Limitations

As a `v0.1.0-beta.1` pre-release, the following limitations and unverified areas remain:

- **AEC Has Not Passed**: Speaker audio may bleed into the microphone track; crosstalk amplitude is unmeasured. Using headphones is recommended.
- **Pending Environmental Validation**: Physical testing on macOS 14.2, long recordings, system sleep/wake recovery, fresh-machine permission onboarding, and multi-Space/full-screen window behaviors remain unverified.
- **Caption & Translation Validation**: Direct on-screen bilingual verification for both window sizes remains incomplete. Doubao text translation requires a separate `volc.speech.mt` grant. The test account lacks this grant, so cloud text translation has not passed end-to-end validation; missing permission produces an explicit error without switching services.

See [Feature Acceptance](docs/feature-acceptance.md) and [Local Verification](docs/local-verification.md) for full records.

## Building from Source

Requires Xcode (tested on Xcode 26.2), Python 3, and SDKs supporting project APIs. Build scripts automatically prepare pinned Meson/Ninja and build the static APM library.

`scripts/build-local.sh` currently checks the maintainer's signing team, `TeamIdentifier=9N7UKH59LC`. Other developers must first adjust this team check and set `MEETINGTAPE_SIGN_IDENTITY` to their own valid Developer ID Application identity. Setting the environment variable alone does not pass the check.

```sh
# Build and test example within the maintainer environment
./scripts/build-desktop.sh debug
swift test
```

## Documentation & License

- [Transcription & Model Guide](docs/transcription.md): Memory profiles, directories, and Doubao protocols.
- [Desktop UI Guide](docs/desktop.md): GUI interactions and session recovery mechanics.
- [Installation & Usage Guide](docs/distribution.md): DMG structure and permission details.
- [Feature Acceptance](docs/feature-acceptance.md): Complete list of verified items and open gaps.

Project source code is released under the [MIT License](LICENSE). See [Resources/ThirdParty](Resources/ThirdParty) and the [model and dependency notices](Resources/Transcription/NOTICE.md) for third-party terms. Model weights are not bundled with the app or repository.
