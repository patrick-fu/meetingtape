# Sign all builds with one Developer ID identity and ship via GitHub Releases

TCC binds grants to code identity and bundle identifier, so every MeetingTape build (development and release) is signed with the team's single Developer ID Application certificate, the CLI is a single signed binary with an embedded Info.plist section (bundle identifier `com.paaatrickfu.meetingtape`, microphone and audio-capture usage strings), and the future GUI will reuse the same bundle identifier. This keeps Microphone/AudioCapture grants alive across rebuilds and upgrades and carries them into the GUI without re-prompting. Distribution is GitHub Releases only (signed arm64 binaries, local install script); notarization is deferred until a public release, and there is no brew tap or CI for now.

## Considered options

- **Ad-hoc signing**: rejected — ad-hoc binaries have no stable designated requirement, so every rebuild looks like a new app and loses TCC grants (Apple DTS confirms re-authorization on update).
- **Brew tap building from source**: rejected — a formula cannot embed the signing private key, so user-machine builds are effectively ad-hoc and lose grants on every `brew upgrade`; if a tap ever becomes relevant, it must download pre-signed release binaries.
- **`.app` bundle for v1**: rejected — heavyweight for a CLI-only phase; the GUI phase upgrades to a bundle reusing the same bundle identifier.
