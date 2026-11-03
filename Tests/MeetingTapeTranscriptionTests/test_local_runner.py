"""Run with python3 -m unittest discover -s Tests/MeetingTapeTranscriptionTests -p 'test_*.py'."""
import importlib.util
from pathlib import Path
from types import ModuleType, SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'local_runner', Path(__file__).resolve().parents[2] / 'Resources/Transcription/local_runner.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class LocalRunnerTests(unittest.TestCase):
    def transcribe(self, generate):
        stt = ModuleType('mlx_audio.stt')
        stt.load = lambda _: SimpleNamespace(generate=generate)
        with patch.dict(sys.modules, {'mlx_audio': ModuleType('mlx_audio'), 'mlx_audio.stt': stt}):
            return runner.transcribe('qwen', Path('/fixture'), [], 30.0)

    def test_token_exhaustion_is_not_a_successful_transcript(self):
        def endless(_samples, **options):
            count = options.get('max_tokens', 8192)
            return SimpleNamespace(text='这个。' * count, segments=[], generation_tokens=count)
        result = self.transcribe(endless)
        self.assertTrue('error' in result, 'exhausted generation must fail')
        self.assertNotIn('text', result)
        self.assertIn('这个。', result['raw']['text'])

    def test_one_second_exhaustion_is_also_rejected(self):
        stt = ModuleType('mlx_audio.stt')
        def endless(_samples, **options):
            count = options.get('max_tokens', 8192)
            return SimpleNamespace(text='嗯' * count, segments=[], generation_tokens=count)
        stt.load = lambda _: SimpleNamespace(generate=endless)
        with patch.dict(sys.modules, {'mlx_audio': ModuleType('mlx_audio'), 'mlx_audio.stt': stt}):
            result = runner.transcribe('qwen', Path('/fixture'), [], 1.0)
        self.assertTrue('error' in result)
        self.assertLessEqual(result['raw']['generation_tokens'], 256)

    def test_ordinary_fillers_and_repetitions_are_preserved(self):
        text = '嗯，嗯，这个这个方案需要再讨论。'
        result = self.transcribe(lambda *_args, **_kwargs: SimpleNamespace(
            text=text, segments=[{'start': 0, 'end': 30, 'text': text}], generation_tokens=24))
        self.assertEqual(result['text'], text)
        self.assertEqual(result['segments'][0]['text'], text)
        self.assertNotIn('error', result)

    def test_quality_failure_is_written_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'model').mkdir()
            (root/'model/config.json').write_text('{}')
            output = root/'output.json'
            args = ['local_runner', '--model-type', 'qwen', '--model', str(root/'model'),
                    '--audio', str(root/'input.wav'), '--output', str(output)]
            failure = {'error': '生成达到上限', 'raw': {'text': '嗯' * 100}}
            with patch.object(sys, 'argv', args), patch.object(runner, 'read_pcm', return_value=([], 30)), \
                 patch.object(runner, 'transcribe', return_value=failure):
                self.assertNotEqual(runner.main(), 0)
            import json
            self.assertEqual(json.loads(output.read_text())['raw'], failure['raw'])


class MossRunnerTests(unittest.TestCase):
    def transcribe(self, generate, parsed, duration=30.0):
        inference = ModuleType('moss_transcribe_diarize.inference_utils')
        inference.DEFAULT_PROMPT = 'transcribe'
        model = ModuleType('moss_transcribe_diarize.mlx.model')
        model.load_model = lambda *_args, **_kwargs: SimpleNamespace(generate=generate)
        parser = ModuleType('moss_transcribe_diarize.transcript_parser')
        parser.parse_transcript = lambda _: parsed
        with patch.dict(sys.modules, {
            'moss_transcribe_diarize': ModuleType('moss_transcribe_diarize'),
            'moss_transcribe_diarize.mlx': ModuleType('moss_transcribe_diarize.mlx'),
            inference.__name__: inference, model.__name__: model, parser.__name__: parser,
        }):
            return runner.transcribe('moss', Path('/fixture'), [], duration)

    def test_exhaustion_preserves_raw_without_publishing_text(self):
        def endless(_samples, **options):
            return SimpleNamespace(text='[0.00][S01] It was a small fish.[1.00]' * 300,
                                   generation_tokens=options['max_tokens'])
        result = self.transcribe(endless, [])
        self.assertTrue('error' in result, 'MOSS exhaustion must fail')
        self.assertNotIn('text', result)
        self.assertIn('small fish', result['raw']['text'])
        self.assertLess(result['raw']['generation_tokens'], 8192)

    def test_short_chunk_exhaustion_has_a_bounded_budget(self):
        result = self.transcribe(lambda _samples, **options: SimpleNamespace(
            text='loop', generation_tokens=options['max_tokens']), [], duration=1.0)
        self.assertTrue('error' in result)
        self.assertLessEqual(result['raw']['generation_tokens'], 512)

    def test_valid_speaker_segments_and_empty_silence_are_kept(self):
        segment = SimpleNamespace(start=0, end=2, text='嗯，这个这个方案。', speaker='S01')
        result = self.transcribe(lambda *_args, **_kwargs: SimpleNamespace(
            text='[0.00][S01]嗯，这个这个方案。[2.00]', generation_tokens=30), [segment])
        self.assertEqual(result['text'], segment.text)
        self.assertEqual(result['segments'][0]['speaker'], 'S01')
        self.assertEqual(result['timestampPrecision'], 'segment')
        empty = self.transcribe(lambda *_args, **_kwargs: SimpleNamespace(
            text='', generation_tokens=0), [])
        self.assertEqual(empty['text'], '')
        self.assertNotIn('error', empty)


if __name__ == '__main__':
    unittest.main()
