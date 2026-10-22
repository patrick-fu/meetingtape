# MeetingTape

Meeting & system audio recorder for humans and agents. One stereo file:
left = system audio (raw), right = microphone (3A, with reported raw fallback
if speech processing fails).
Native macOS CLI (Swift, CoreAudio tap + AVAudioEngine), designed to be
operated end-to-end by coding agents via progressive-disclosure help.
Later phases add a GUI on top of the same recording engine.

## Agent skills

### Issue tracker

GitHub Issues on patrick-fu/meetingtape, driven with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles with default label strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
