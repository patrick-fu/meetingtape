import contextlib
import importlib.util
import io
import json
from pathlib import Path
import types
import unittest

import numpy as np

spec = importlib.util.spec_from_file_location('local_live_runner', Path(__file__).parents[2] / 'Resources/Transcription/local_live_runner.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Recognizer:
    def __init__(self):
        self.inputs = []

    def create_stream(self):
        return self

    def accept_waveform(self, rate, samples):
        self.input = samples.copy()

    def decode_stream(self, stream):
        self.inputs.append(self.input)
        self.result = types.SimpleNamespace(text='原文 English')


class VAD:
    def __init__(self, completed_at=None):
        self.end = 0
        self.start = 0
        self.completed_at = completed_at
        self.events = []

    def accept_waveform(self, audio):
        self.end += len(audio)
        if self.completed_at and self.end >= self.completed_at and self.start == 0:
            self.events.append(types.SimpleNamespace(start=0))
            self.start = None
        elif self.start is None and not self.completed_at:
            self.start = self.end - len(audio)

    def empty(self):
        return not self.events

    @property
    def front(self):
        return self.events[0]

    def pop(self):
        self.events.pop(0)

    def is_speech_detected(self):
        return self.start is not None

    @property
    def current_segment(self):
        return types.SimpleNamespace(start=self.start)

    def flush(self):
        if self.start is not None:
            self.events.append(types.SimpleNamespace(start=self.start))
            self.start = None


class OriginalPCMTests(unittest.TestCase):
    def exercise(self, length, completed_at=None):
        recognizer = Recognizer()
        runtime = runner.CaptionRuntime(recognizer, VAD(completed_at), 512, 12.25, np)
        raw = (np.arange(length, dtype=np.int64) % 30000 - 15000).astype('<i2')
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            for offset in range(0, length, 64000):
                runtime.append(raw[offset:offset + 64000].tobytes())
            runtime.finish()
        self.assertEqual(runtime.received, length)
        self.assertLessEqual(runtime.max_pcm, 320000)
        for start, end in runtime.ranges:
            expected = raw[start:end].astype(np.float32) / 32768
            self.assertTrue(any(np.array_equal(expected, audio) for audio in recognizer.inputs))
        return runtime

    def test_eof_includes_original_181_sample_tail(self):
        runtime = self.exercise(16000 + 181)
        self.assertEqual(runtime.ranges, [[0, 16181]])
        self.assertEqual(runtime.finals[-1]['end'], 12.25 + 16181 / 16000)

    def test_45_seconds_split_without_overlap_or_sample_loss(self):
        runtime = self.exercise(45 * 16000 + 181)
        self.assertEqual(runtime.ranges, [[0, 320000], [320000, 640000], [640000, 720181]])

    def test_empty_revision_withdraws_draft_and_empty_final_keeps_it_cleared(self):
        for retain_final in (False, True):
            with self.subTest(retain_final=retain_final):
                recognizer = Recognizer()
                results = iter(['旧草稿', '', ''])
                def decode(stream):
                    recognizer.result = types.SimpleNamespace(text=next(results))
                recognizer.decode_stream = decode
                runtime = runner.CaptionRuntime(recognizer, VAD(), 512, 12.25, np)
                runtime.pcm = np.zeros(16000, dtype=np.float32)
                runtime.active = 0
                finals = [dict(id='0', start=1, end=2, text='已确认', final=True)] if retain_final else []
                runtime.finals = finals.copy()
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                    runtime.decode(512, False)
                    runtime.decode(1024, False)
                    runtime.finish()
                events = [json.loads(line) for line in output.getvalue().splitlines()]
                captions = [event['segments'] for event in events if event['type'] == 'caption']
                self.assertEqual(captions[0][-1]['text'], '旧草稿')
                self.assertEqual(captions[1], finals)
                self.assertEqual(captions[-1], finals)
                self.assertEqual(events[-1]['type'], 'finished')
                self.assertFalse(runtime.has_draft)

    def test_completed_speech_inside_one_message_is_finalized(self):
        runtime = self.exercise(3 * 16000, completed_at=10240)
        self.assertEqual(runtime.ranges, [[0, 10240]])


if __name__ == '__main__':
    unittest.main()
