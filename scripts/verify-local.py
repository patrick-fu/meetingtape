#!/usr/bin/env python3
"""Verify a signed local CLI. Live recording requires --record."""
import argparse
import array
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import tempfile
import time
import traceback


class Run:
    def __init__(self, directory):
        self.directory = directory
        self.steps = []
        self.env = os.environ.copy()
        state = directory / "state"
        state.mkdir(mode=0o700)
        self.env["MEETINGTAPE_STATE_DIR"] = str(state)

    def command(self, args, expected=0, timeout=60):
        result = subprocess.run([str(x) for x in args], env=self.env, capture_output=True,
                                text=True, timeout=timeout)
        self.steps.append({"command": [str(x) for x in args], "exit": result.returncode,
                           "stdout": result.stdout, "stderr": result.stderr})
        self.save("RUNNING")
        if expected is not None and result.returncode != expected:
            raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr.strip()}")
        return result

    def save(self, status, **details):
        (self.directory / "report.json").write_text(json.dumps(
            {"status": status, "steps": self.steps, **details}, indent=2) + "\n")


def identity(path):
    return {"path": str(path), "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def media(run, path, channels, raw=False):
    info = json.loads(run.command(["ffprobe", "-v", "error", "-select_streams", "a:0",
                                  "-show_entries", "stream=codec_name,sample_rate,channels:format=duration",
                                  "-of", "json", path]).stdout)
    stream = info["streams"][0]
    assert stream["sample_rate"] == "48000" and stream["channels"] == channels, info
    assert stream["codec_name"] == ("pcm_f32le" if raw else "aac"), info
    decoded = run.directory / (path.stem + ".f32")
    run.command(["ffmpeg", "-v", "error", "-y", "-i", path,
                 "-f", "f32le", "-acodec", "pcm_f32le", decoded])
    values = array.array("f")
    values.frombytes(decoded.read_bytes())
    assert len(values) > 0 and len(values) % channels == 0
    assert all(math.isfinite(x) for x in values)
    return values, info


def compare_prefix(source, decoded, spans, channels, header=68, lossy=True):
    pcm = array.array("f")
    committed_bytes = sum(span["frameCount"] for span in spans) * channels * 4
    pcm.frombytes(source.read_bytes()[header:header + committed_bytes])
    offset = 0
    previous_end = 0
    for span in spans:
        count = span["frameCount"] * channels
        target = span["startFrame"] * channels
        margin = 4096 * channels if lossy else 0
        gap = decoded[previous_end + margin:target - margin] if target > previous_end + 2 * margin else []
        assert not gap or max(abs(x) for x in gap) <= (0.003 if lossy else 0)
        assert len(decoded) >= target + count
        for begin in range(0, count, channels * 12_000):
            length = min(count - begin, channels * 12_000)
            expected = pcm[offset + begin:offset + begin + length]
            actual = decoded[target + begin:target + begin + length]
            assert len(expected) == len(actual) == length
            error = math.sqrt(sum((x - y) ** 2 for x, y in zip(expected, actual)) / length)
            rms = math.sqrt(sum(x * x for x in expected) / length)
            assert error <= max(0.00002, rms * 0.35) if lossy else error == 0
        offset += count
        previous_end = target + count


def recover(run, binary, directory, out, manifest):
    audio = run.directory / (directory.name + "-source.caf")
    raw = run.directory / (directory.name + "-raw.caf")
    shutil.copyfile(directory / "audio.caf", audio)
    if manifest.get("rawFile"):
        shutil.copyfile(directory / "microphone.caf", raw)
    existing = {p: identity(p) for p in out.iterdir() if p.is_file()}
    run.command([binary, "recover", directory, "--out", out])
    added = [p for p in out.iterdir() if p.suffix == ".m4a" and p not in existing]
    assert len(added) == 1
    main = added[0]
    decoded, info = media(run, main, 2)
    assert abs(len(decoded) // 2 - manifest["timelineFrames"]) <= 4096
    compare_prefix(audio, decoded, manifest["spans"], 2)
    metadata = json.loads(main.with_suffix(".json").read_text())
    assert metadata["state"] == "completed"
    assert Path(metadata["outputPath"]).resolve(strict=True) == main.resolve(strict=True)
    assert metadata["committedSeconds"] == manifest["timelineFrames"] / 48000
    assert metadata["degradedIntervals"] == manifest["snapshot"]["degradedIntervals"]
    assert metadata.get("recoveryNote")
    if manifest.get("rawFile"):
        raw_values, _ = media(run, Path(metadata["rawOutputPath"]), 1, raw=True)
        compare_prefix(raw, raw_values, manifest["spans"], 1, lossy=False)
    for path, value in existing.items():
        assert identity(path) == value
    return {"output": identity(main), "format": info, "metadata": metadata}


def offline_recovery(run, binary, root, out):
    fixture = run.directory / "recovery-fixture"
    run.command(["swiftc", "-swift-version", "6", "-target", "arm64-apple-macosx14.2",
                 root / "Sources/MeetingTapeCore/SessionModels.swift",
                 root / "Sources/MeetingTapeCore/RecoveryStore.swift",
                 root / "Tests/Fixtures/RecoveryFixture.swift", "-o", fixture])
    source = run.directory / "synthetic-crash"
    source.mkdir(mode=0o700)
    child = subprocess.Popen([str(fixture), str(source)], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    try:
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        assert selector.select(15), "recovery fixture did not become ready"
        assert child.stdout.readline() == "READY\n"
        refused = run.command([binary, "recover", source, "--out", out], expected=4)
        assert "active writer" in refused.stderr
    finally:
        child.kill()
        child.wait(timeout=10)
    assert child.returncode == -signal.SIGKILL
    manifest = json.loads((source / "manifest.json").read_text())
    assert manifest["audioFrames"] == 96000 and manifest["timelineFrames"] == 240000
    assert (source / "audio.caf").stat().st_size == 68 + 144000 * 8
    (run.directory / "synthetic-manifest.json").write_text(json.dumps(manifest, indent=2))
    cache = Path(run.env["MEETINGTAPE_STATE_DIR"]) / "last-session.json"
    previous = dict(manifest["snapshot"], state="failed", failureReason="verification crash")
    cache.write_text(json.dumps(previous))
    assert json.loads(run.command([binary, "status", "--json"]).stdout)["state"] == "failed"
    with (cache.parent / "startup.lock").open("a") as startup:
        fcntl.flock(startup, fcntl.LOCK_EX)
        result = recover(run, binary, source, out, manifest)
    assert json.loads(run.command([binary, "status", "--json"]).stdout)["state"] == "idle"
    return result


def live_recording(run, binary, out, seconds):
    started = False
    try:
        start_bound = time.monotonic()
        run.command([binary, "start", "--out", out, "--keep-raw"], timeout=40)
        started = True
        time.sleep(seconds)
        snapshot = json.loads(run.command([binary, "status", "--json"]).stdout)
        assert snapshot["state"] == "recording", snapshot
        pid = snapshot["processID"]
        process = run.command(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="]).stdout.strip()
        assert process.startswith(str(binary) + " __host ")
        ready_path = Path(process.rsplit(" --ready-file ", 1)[1].removesuffix(" --keep-raw"))
        assert ready_path.parent.resolve(strict=True) == Path(run.env["MEETINGTAPE_STATE_DIR"]).resolve(strict=True)
        os.kill(pid, signal.SIGKILL)
        started = False
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
            if not result.stdout.strip() or result.stdout.strip().startswith("Z"):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("the owned recording host did not exit after SIGKILL")
        exit_bound = time.monotonic()
        directory = Path(snapshot["recoveryPath"])
        manifest = json.loads((directory / "manifest.json").read_text())
        assert manifest["snapshot"]["sessionID"] == snapshot["sessionID"]
        result = recover(run, binary, directory, out, manifest)
        last_audio = max(x["startFrame"] + x["frameCount"] for x in manifest["spans"])
        observed_tail = snapshot["elapsedSeconds"] - last_audio / 48000
        assert -0.25 <= observed_tail <= 5, observed_tail
        result["observed_tail_seconds"] = observed_tail
        tail_upper_bound = exit_bound - start_bound - last_audio / 48000
        assert 0 <= tail_upper_bound <= 5, tail_upper_bound
        result["tail_upper_bound_seconds"] = tail_upper_bound
        return result
    finally:
        if started:
            run.command([binary, "stop"], expected=None, timeout=120)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--seconds", type=int, default=12)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    out = args.out.resolve(strict=True)
    assert binary.is_file() and os.access(binary, os.X_OK)
    assert out.is_dir() and os.access(out, os.W_OK)
    assert 8 <= args.seconds <= 60
    root = Path(__file__).resolve().parent.parent
    directory = Path(tempfile.mkdtemp(prefix="meetingtape-acceptance-", dir=out))
    run = Run(directory)
    details = {"binary": identity(binary), "live_recording": "UNVERIFIED"}
    try:
        for topic in [None, "start", "status", "stop", "recover", "doctor"]:
            run.command([binary, "help"] + ([topic] if topic else []))
        run.command([binary, "doctor", "--out", out])
        status = json.loads(run.command([binary, "status", "--json"]).stdout)
        assert status["state"] == "idle", status
        details["synthetic_recovery"] = offline_recovery(run, binary, root, out)
        if args.record:
            details["live_recording"] = live_recording(run, binary, out, args.seconds)
        details["unverified"] = ["independent source identity", "real-world 3A quality", "device changes",
                                 "sleep/wake", "long-session drift", "macOS 14.2 runtime"]
        run.save("PARTIAL", **details)
        print("PARTIAL: completed checks are recorded; real-device acceptance remains open.")
        print(directory / "report.json")
        return 0
    except Exception as error:
        run.save("FAILED", error=repr(error), traceback=traceback.format_exc(), **details)
        print(repr(error))
        print(directory / "report.json")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
