#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import math
import resource
import sys
import time

RATE = 16000
LIMIT = 20 * RATE
MAX_LINE = 172000


def emit(value):
    print(json.dumps(value, ensure_ascii=False, allow_nan=False), flush=True)


def process_statistics(decode_elapsed=0.0, decoded_audio=0.0):
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return dict(scope='runner-process', cpuSeconds=usage.ru_utime + usage.ru_stime,
                peakResidentBytes=int(usage.ru_maxrss) * (1 if sys.platform == 'darwin' else 1024),
                decodeElapsedSeconds=decode_elapsed, decodedAudioSeconds=decoded_audio)


class CaptionRuntime:
    def __init__(self, recognizer, vad, window, start_at, np):
        self.recognizer, self.vad, self.window = recognizer, vad, window
        self.start_at, self.np = start_at, np
        self.pcm = np.empty(0, dtype=np.float32)
        self.base = self.received = self.fed = self.floor = 0
        self.active = None
        self.finals = []
        self.last_decode = -math.inf
        self.max_pcm = 0
        self.ranges = []
        self.has_draft = False
        self.asr_calls = 0

    def decode(self, end, final):
        if self.active is None or end <= self.active:
            return
        if len(self.ranges) >= 20000:
            raise ValueError('字幕分段超过 20000 段上限')
        audio = self.pcm[self.active - self.base:end - self.base]
        if len(audio) != end - self.active or len(audio) > LIMIT:
            raise ValueError('原始音频窗口不完整')
        stream = self.recognizer.create_stream()
        stream.accept_waveform(RATE, audio)
        decode_start = time.monotonic()
        self.recognizer.decode_stream(stream)
        decode_elapsed = time.monotonic() - decode_start
        self.asr_calls += 1
        self.last_decode = time.monotonic()
        text = stream.result.text.strip()
        segment = dict(id=str(len(self.finals)), start=self.start_at + self.active / RATE,
                       end=self.start_at + end / RATE, text=text, final=final)
        if final:
            self.ranges.append([self.active, end])
            if text:
                self.finals.append(segment)
            self.floor = end
            self.active = None
        if text or self.has_draft or (final and self.finals):
            emit(dict(type='caption', segments=self.finals if final or not text else self.finals + [segment],
                      statistics=process_statistics(decode_elapsed, len(audio) / RATE)))
        self.has_draft = not final and bool(text)

    def gate(self, end):
        completed = False
        while not self.vad.empty():
            start = self.vad.front.start
            if self.active is None:
                self.active = max(self.base, self.floor, start)
            self.vad.pop()
            completed = True
        if self.vad.is_speech_detected() and self.active is None:
            self.active = max(self.base, self.floor, self.vad.current_segment.start)
        if completed and self.active is not None:
            self.decode(end, True)
        elif self.active is not None and end - self.active >= LIMIT:
            self.decode(self.active + LIMIT, True)
            # Keep Silero's sample clock aligned with the retained PCM.
            self.vad.flush()
            while not self.vad.empty():
                self.vad.pop()
        elif self.active is not None and time.monotonic() - self.last_decode >= 1:
            self.decode(end, False)

    def append(self, raw):
        audio = self.np.frombuffer(raw, dtype='<i2').astype(self.np.float32) / 32768
        self.received += len(audio)
        offset = 0
        while offset < len(audio):
            available = self.base + len(self.pcm)
            count = min(self.window - (available - self.fed), len(audio) - offset)
            if self.active is not None:
                count = min(count, self.active + LIMIT - available)
            self.pcm = self.np.concatenate((self.pcm, audio[offset:offset + count]))
            offset += count
            self.max_pcm = max(self.max_pcm, len(self.pcm))
            available = self.base + len(self.pcm)
            at_limit = self.active is not None and available == self.active + LIMIT
            if available - self.fed >= self.window or at_limit:
                self.vad.accept_waveform(self.pcm[self.fed - self.base:available - self.base])
                self.fed = available
                self.gate(available)
            keep = self.active if self.active is not None else max(self.floor, self.fed - RATE)
            if keep > self.base:
                self.pcm = self.pcm[keep - self.base:].copy()
                self.base = keep

    def finish(self):
        end = self.base + len(self.pcm)
        if end > self.fed:
            self.vad.accept_waveform(self.pcm[self.fed - self.base:])
            self.fed = end
        self.vad.flush()
        while not self.vad.empty():
            if self.active is None:
                self.active = max(self.base, self.floor, self.vad.front.start)
            self.vad.pop()
        self.decode(end, True)
        emit(dict(type='finished', statistics=process_statistics()))
        print(json.dumps(dict(source_samples=self.received, max_pcm_samples=self.max_pcm,
                              final_ranges=self.ranges, asr_calls=self.asr_calls,
                              max_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == 'darwin' else 1024))), file=sys.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True)
    parser.add_argument('--tokens', required=True)
    parser.add_argument('--vad', required=True)
    parser.add_argument('--start-at', type=float, default=0)
    args = parser.parse_args()
    if not math.isfinite(args.start_at) or args.start_at < 0:
        raise ValueError('录音起点必须为非负有限秒数')
    import numpy as np
    import sherpa_onnx
    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=args.model, tokens=args.tokens, language='auto', use_itn=True,
        num_threads=2, provider='cpu')
    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = args.vad
    config.sample_rate = RATE
    config.num_threads = 2
    vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=21)
    runtime = CaptionRuntime(recognizer, vad, config.silero_vad.window_size, args.start_at, np)
    emit(dict(type='ready'))
    while True:
        line = sys.stdin.buffer.readline(MAX_LINE + 1)
        if not line:
            break
        if len(line) > MAX_LINE:
            raise ValueError('音频消息超过 4 秒上限')
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError('消息必须为 JSON 对象')
        if set(value) == {'finish'} and value['finish'] is True:
            break
        if set(value) != {'audio'} or not isinstance(value['audio'], str):
            raise ValueError('消息必须且只能包含 audio 或 finish:true')
        try:
            raw = base64.b64decode(value['audio'], validate=True)
        except ValueError:
            raise ValueError('音频必须为有效 base64') from None
        if not raw or len(raw) % 2 or len(raw) > 4 * RATE * 2:
            raise ValueError('音频必须为不超过 4 秒的 PCM16LE')
        runtime.append(raw)
    runtime.finish()
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        emit(dict(type='error', message=str(error)))
        raise SystemExit(1)
