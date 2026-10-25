# MeetingTape

Glossary for the MeetingTape domain: a lightweight macOS tool that records microphone and system audio into one stereo file.

## Language

**MeetingTape**:
The product: a lightweight macOS CLI (later GUI) that records microphone and system audio into a single stereo file, usable directly by coding agents.
_Avoid_: recorder, the tool

**System audio**:
Sound produced by the Mac itself (apps, media, calls), captured through a CoreAudio process tap; occupies the left channel of the output file.
_Avoid_: internal recording, loopback, desktop audio

**Microphone audio**:
The user's microphone input in the right channel of the output file, normally after 3A processing and retained raw during degraded intervals.
_Avoid_: mic track, voice input

**3A**:
Echo cancellation, noise suppression, and automatic gain control applied to microphone audio during normal recording; the echo canceller uses system audio as its reference.
_Avoid_: audio enhancement

**Raw microphone audio**:
The microphone signal before 3A processing.

**Degraded interval**:
A time range in a session during which microphone audio is retained without 3A because speech processing has failed.

**Capture interruption**:
A time range in an active session during which one or both audio sources are temporarily unavailable.

**Session**:
One recording from start to stop, including automatic recovery after system sleep or device changes; at most one session is active at a time.
_Avoid_: recording job

**转写（Transcription）**:
对已保存的录音进行语音识别，生成可按时间定位的文字。

**转写任务（Transcription task）**:
对一段已保存的录音，使用所选一个或多个模型生成转写结果的一次处理。

**转写结果（Transcript）**:
识别模型对录音生成的正文与时间分段，关联原录音用于浏览和回听定位。

**模型选择（Model selection）**:
一次转写使用的一个或多个识别模型；用户可以设置默认选择，并在发起转写时调整。

**Developer ID**:
The Apple code-signing identity type used for every MeetingTape build; its designated requirement is anchored to the signing team, so certificate renewal keeps the identity stable.
_Avoid_: ad-hoc signing, self-signing

**Designated requirement**:
The stable identity predicate macOS (including TCC) evaluates for signed code; team-anchored for Developer ID, unchanged by rebuilds.
_Avoid_: code hash

**Responsible process**:
The process macOS attributes a permission request to, determined by the launch chain (terminal, agent host, scheduler) rather than always being the binary itself.
_Avoid_: parent process, caller

**Bundle identifier**:
`com.paaatrickfu.meetingtape`, shared by the CLI and the future GUI so TCC grants carry across product forms.
