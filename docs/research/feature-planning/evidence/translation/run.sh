#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../../../../.." && pwd)
cd "$repo_root"
probe_sources=docs/research/feature-planning/evidence/translation
probe_output=$(mktemp -d "${TMPDIR:-/tmp}/meetingtape-translation.XXXXXX")
trap 'rm -rf "$probe_output"' EXIT
python3 "$probe_sources/make_probe.py" "$probe_output"
swiftc -parse-as-library Sources/MeetingTapeTranscription/SubtitleModels.swift Sources/MeetingTapeTranscription/CaptionDraftBuffer.swift "$probe_output/Models.swift" "$probe_output/Schedule.swift" "$probe_sources/Main.swift" -o "$probe_output/translation-probe"
"$probe_output/translation-probe" "$probe_output/archive"
