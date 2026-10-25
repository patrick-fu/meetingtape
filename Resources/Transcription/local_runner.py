#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
import time
import wave


def retain_owner_lease() -> int | None:
    value = os.environ.get("MEETINGTAPE_OWNER_PID")
    if value is None:
        return None
    try:
        owner = int(value)
    except ValueError as error:
        raise ValueError("推理父进程 PID 无效") from error
    if owner <= 1 or os.getppid() != owner:
        raise ValueError("推理父进程已退出")
    lease = os.dup(0)
    if not stat.S_ISREG(os.fstat(lease).st_mode):
        os.close(lease)
        raise ValueError("推理租约必须来自已锁定的普通文件")
    if os.getppid() != owner:
        os.close(lease)
        raise ValueError("推理父进程已退出")

    def watch_owner() -> None:
        while True:
            if os.getppid() != owner:
                os._exit(75)
            time.sleep(0.1)

    threading.Thread(target=watch_owner, name="meetingtape-owner", daemon=True).start()
    return lease


def absolute_path(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise argparse.ArgumentTypeError("必须使用绝对路径")
    return path


def json_value(value):
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        return json_value(dataclasses.asdict(value))
    if isinstance(value, dict):
        return {str(key): json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_value(item) for item in value]
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if hasattr(value, "tolist"):
        return json_value(value.tolist())
    if hasattr(value, "__dict__"):
        return json_value(vars(value))
    raise TypeError(f"后端返回了不支持的 JSON 类型：{type(value).__name__}")


def read_pcm(path: Path):
    import numpy as np

    with wave.open(str(path), "rb") as audio:
        width = audio.getsampwidth()
        if audio.getnchannels() != 1 or audio.getframerate() != 16000 or audio.getcomptype() != "NONE":
            raise ValueError("输入必须为单声道、16 kHz、未压缩整数 PCM WAV")
        count = audio.getnframes()
        data = audio.readframes(count)
    if not count or len(data) != count * width:
        raise ValueError("输入 WAV 为空或未完整保存")
    if width == 1:
        samples = (np.frombuffer(data, dtype=np.uint8).astype(np.float32) - 128) / 128
    elif width in (2, 4):
        samples = np.frombuffer(data, dtype=f"<i{width}").astype(np.float32) / (2 ** (8 * width - 1))
    elif width == 3:
        packed = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        signed = packed[:, 0] | (packed[:, 1] << 8) | (packed[:, 2] << 16)
        samples = ((signed ^ 0x800000) - 0x800000).astype(np.float32) / 8388608
    else:
        raise ValueError("输入 WAV 必须为 8、16、24 或 32 位整数 PCM")
    return samples, count / 16000


def normalize_segments(segments, duration: float) -> list[dict]:
    normalized = []
    for segment in segments or []:
        item = json_value(segment)
        if not isinstance(item, dict):
            raise ValueError("后端时间段格式不正确")
        start, end = item.get("start"), item.get("end")
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            continue
        if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start or end > duration + 0.1:
            continue
        text = str(item.get("text") or "").strip()
        if not text:
            continue
        result = {"start": float(start), "end": min(float(end), duration), "text": text}
        speaker = item.get("speaker") or item.get("speaker_id")
        if isinstance(speaker, str) and speaker.strip():
            result["speaker"] = speaker.strip()
        normalized.append(result)
    return sorted(normalized, key=lambda item: (item["start"], item["end"]))


def transcribe(family: str, model_path: Path, samples, duration: float) -> dict:
    if family == "qwen":
        from mlx_audio.stt import load

        model = load(str(model_path))
        result = model.generate(samples, chunk_duration=30.0, batch_size=1, verbose=False)
        segments = normalize_segments(result.segments, duration)
        text = result.text
        precision = "chunk"
    else:
        from moss_transcribe_diarize.inference_utils import DEFAULT_PROMPT
        from moss_transcribe_diarize.mlx.model import load_model
        from moss_transcribe_diarize.transcript_parser import parse_transcript

        model = load_model(str(model_path), strict=False)
        result = model.generate(
            samples, prompt=DEFAULT_PROMPT, max_tokens=8192, temperature=0.0,
            top_p=1.0, top_k=0, prefill_step_size=2048,
        )
        parsed = parse_transcript(result.text)
        segments = normalize_segments(parsed, duration)
        text = "\n".join(item.text for item in parsed) if parsed else result.text
        if len(segments) != len(parsed):
            segments = []
        precision = "segment" if segments else "chunk"
    return {"text": text, "segments": segments, "timestampPrecision": precision, "raw": json_value(result)}


def write_json(path: Path, value: dict) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, ensure_ascii=False, allow_nan=False)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    _owner_lease = retain_owner_lease()
    parser = argparse.ArgumentParser(description="离线执行单个本地转写模型；输入由 MeetingTape 转换为单声道 16 kHz PCM WAV。")
    parser.add_argument("--model-type", choices=("qwen", "moss"), required=True)
    parser.add_argument("--model", type=absolute_path, required=True)
    parser.add_argument("--audio", type=absolute_path, required=True)
    parser.add_argument("--output", type=absolute_path, required=True)
    args = parser.parse_args()
    if not args.model.is_dir() or not (args.model / "config.json").is_file():
        raise ValueError("本地模型目录无效；请先安装并完成验证")
    if args.output.resolve() == args.audio.resolve() or args.output.resolve().is_relative_to(args.model.resolve()):
        raise ValueError("结果不能覆盖输入录音或模型文件")
    for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_DATASETS_OFFLINE"):
        os.environ[key] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"
    samples, duration = read_pcm(args.audio)
    write_json(args.output, transcribe(args.model_type, args.model.resolve(), samples, duration))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"本地转写失败：{error}", file=sys.stderr)
        raise SystemExit(1)
