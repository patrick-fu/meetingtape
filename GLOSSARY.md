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
The user's microphone input after 3A processing; occupies the right channel of the output file.
_Avoid_: mic track, voice input

**3A**:
Echo cancellation, noise suppression, and automatic gain control applied to microphone audio, always on; the echo canceller uses system audio as its reference.
_Avoid_: audio enhancement

**Session**:
One recording run from `start` to `stop`; at most one session is active at a time and there is no pause or resume.
_Avoid_: recording job

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
