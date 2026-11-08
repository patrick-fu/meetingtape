#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import urllib.request

REVISION = '355f4d4884d8afd08aef04b9007a8556d7b463b2'
REPO = 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09'
RUNTIME = 'sherpa-onnx-2.0.1'
MODEL_BASE = f'https://huggingface.co/{REPO}/resolve/{REVISION}/'
ARTIFACTS = {
    'model.int8.onnx': (MODEL_BASE + 'model.int8.onnx', 237115547, '12ca1a2ae7ecf3e0019ef2822307ee0b5cadc9196569e379b4c4026f8205276d'),
    'tokens.txt': (MODEL_BASE + 'tokens.txt', 315894, 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc'),
    'silero_vad.onnx': ('https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx', 643854, '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6'),
    'LICENSE-sherpa-onnx': ('https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/LICENSE', 11358, 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'),
    'LICENSE-Silero': ('https://raw.githubusercontent.com/snakers4/silero-vad/v4.0/LICENSE', 1075, '2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b'),
    'LICENSE-SenseVoice': ('https://raw.githubusercontent.com/FunAudioLLM/SenseVoice/586bbdb2b052f4fe19322581825228b6810a9fb3/LICENSE', 1062, '4bc3bffe14ebe38cc67309991e04f92866835eac1c5e2e1abd37163f67c6de5f'),
}

PACKAGES = {'numpy': ('2.0.2', ['f15975dfec0cf2239224d80e32c3170b1d168335eaedee69da84fbe9f1f9cd04', '8c5713284ce4e282544c68d1c3b2c7161d38c256d2eefc93c1d683cf47683e66', '11a76c372d1d37437857280aa142086476136a8c0f373b2e648ab2c8f18fb195', '807ec44583fd708a21d4a11d94aedf2f4f3c3719035c76a2bbe1fe8e217bdc57', '8df823f570d9adf0978347d1f926b2a867d5608f434a7cff7f7908c6570dcf5e', '9a92ae5c14811e390f3767053ff54eaee3bf84576d99a2456391401323f4ec2c', '423e89b23490805d2a5a96fe40ec507407b8ee786d66f7328be214f9679df6dd', '2b2955fa6f11907cf7a70dab0d0755159bca87755e831e47932367fc8f2f2d0b']), 'sherpa-onnx': ('2.0.1', ['a05077feb84f7aeb550f3e6cf97e830024a221fe3a584289232f4647727ac5c6', 'f4f137e1b3df4b3ee5ad73bc0d9b9940210c7743dc009463c7426acabad60a11', '89841ea2b253275f11135a232b671123f46a145536d82bf66cf07087fd93a4d1', 'a18f47204f6b2a1d81769e736ddf9fdfb23cff01021c17491f2faf097ced6677']), 'sherpa-onnx-core': ('2.0.1', ['82ab505a835e616f568ba6804555969e1b5699341d2b18eb27f0083b068b61ff'])}


class InstallationInterrupted(RuntimeError):
    pass


def atomic_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w') as output:
            json.dump(value, output, ensure_ascii=False, allow_nan=False)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def verified(path, spec):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != spec[1]:
        return False
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest() == spec[2]


def download(path, spec):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(spec[0], timeout=60) as source, path.open('wb') as output:
                while True:
                    block = source.read(1024 * 1024)
                    if not block:
                        break
                    if output.tell() + len(block) > spec[1]:
                        raise ValueError('公开制品大小不匹配')
                    output.write(block)
            if not verified(path, spec):
                raise ValueError('公开制品完整性检查失败')
            return
        except InstallationInterrupted:
            raise
        except Exception:
            path.unlink(missing_ok=True)
            if attempt == 2:
                raise RuntimeError('下载固定版本制品失败：' + path.name) from None


def command(arguments, root, environment, timeout=900):
    child = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment)
    timer = threading.Timer(timeout, child.kill)
    timer.start()
    tail = b''
    try:
        while True:
            block = child.stdout.read(4096)
            if not block:
                break
            tail = (tail + block)[-128 * 1024:]
            (root / 'install.log').write_bytes(tail)
        if child.wait():
            raise RuntimeError('本地运行时安装检查失败，请查看 install.log')
    finally:
        timer.cancel()
        if child.poll() is None:
            child.kill()
            child.wait()


def installation(directory):
    return dict(schemaVersion=1, python=str(directory / 'venv/bin/python'),
                model=str(directory / 'model/model.int8.onnx'), tokens=str(directory / 'model/tokens.txt'),
                vad=str(directory / 'model/silero_vad.onnx'), revision=REVISION,
                runtimeVersion=RUNTIME, ready=True)


def check(value, root, environment):
    if value.get('schemaVersion') != 1 or value.get('revision') != REVISION or value.get('runtimeVersion') != RUNTIME or value.get('ready') is not True:
        raise ValueError('既有本地字幕安装版本不匹配')
    directory = Path(value['model']).parent.parent
    directory.relative_to(root / 'installations')
    if value != installation(directory) or directory.is_symlink():
        raise ValueError('既有本地字幕安装路径不匹配')
    for name, spec in ARTIFACTS.items():
        if not verified(directory / 'model' / name, spec):
            raise ValueError('既有本地字幕制品完整性检查失败')
    expected = {name: item[0] for name, item in PACKAGES.items()}
    code = 'import importlib.metadata as m,json,sys; expected=json.loads(sys.argv[1]); assert all(m.version(k)==v for k,v in expected.items())'
    command([value['python'], '-I', '-B', '-c', code, json.dumps(expected)], root, environment, 30)
    runner = Path(__file__).with_name('local_live_runner.py')
    arguments = [value['python'], '-I', '-B', str(runner), '--model', value['model'], '--tokens', value['tokens'], '--vad', value['vad']]
    payload = json.dumps({'audio': base64.b64encode(bytes(32000)).decode()}) + '\n{"finish":true}\n'
    result = subprocess.run(arguments, input=payload, text=True, capture_output=True, timeout=60, env=environment)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    if result.returncode or len(events) != 2 or events[0] != {'type': 'ready'} or events[1].get('type') != 'finished':
        raise ValueError('本地字幕静音握手未通过')


def main():
    parser = argparse.ArgumentParser(description='安装固定版本的本地实时字幕运行时')
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    if not args.root.is_absolute() or args.root == Path('/') or args.root.is_symlink():
        raise ValueError('请使用专用的绝对安装目录')
    args.root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root = args.root.resolve()
    status = root / 'status.json'
    environment = {k: v for k, v in os.environ.items() if not k.startswith(('PIP_', 'PYTHON', 'HF_', 'HUGGINGFACE_', 'UV_'))}
    environment.update(PIP_CONFIG_FILE=os.devnull, PIP_DISABLE_PIP_VERSION_CHECK='1', PYTHONNOUSERSITE='1')
    lock = os.open(root / 'bootstrap.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    staging = None
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock)
        return 1
    try:
        atomic_json(status, dict(state='installing', phase='checking'))
        active = root / 'installation.json'
        value = None
        if active.is_file():
            try:
                candidate = json.loads(active.read_text())
                if not isinstance(candidate, dict):
                    raise ValueError('既有安装描述必须为对象')
                check(candidate, root, environment)
                value = candidate
            except InstallationInterrupted:
                raise
            except (ValueError, TypeError, KeyError, OSError, RuntimeError, subprocess.TimeoutExpired):
                atomic_json(status, dict(state='installing', phase='repairing'))
        if value is None:
            if platform.system() != 'Darwin' or platform.machine() != 'arm64' or not (3, 9) <= sys.version_info[:2] <= (3, 12):
                raise ValueError('需要 Apple Silicon macOS 和 Python 3.9–3.12')
            parent = root / 'installations'
            parent.mkdir(exist_ok=True, mode=0o700)
            if parent.is_symlink():
                raise ValueError('运行时目录不能为符号链接')
            staging = Path(tempfile.mkdtemp(prefix='.install-', dir=parent))
            model = staging / 'model'
            model.mkdir()
            atomic_json(status, dict(state='installing', phase='runtime'))
            command([sys.executable, '-I', '-B', '-m', 'venv', str(staging / 'venv')], root, environment)
            requirements = staging / 'requirements.txt'
            requirements.write_text('\n'.join(name + '==' + version + ' ' + ' '.join('--hash=sha256:' + h for h in hashes) for name, (version, hashes) in PACKAGES.items()) + '\n')
            command([str(staging / 'venv/bin/python'), '-I', '-B', '-m', 'pip', '--isolated', 'install', '--index-url', 'https://pypi.org/simple', '--only-binary=:all:', '--require-hashes', '--retries', '2', '--timeout', '60', '-r', str(requirements)], root, environment)
            for name, spec in ARTIFACTS.items():
                atomic_json(status, dict(state='installing', phase='model' if name.endswith(('.onnx', '.txt')) else 'licenses'))
                download(model / name, spec)
            atomic_json(model / 'provenance.json', dict(revision=REVISION, repository=REPO, runtimeVersion=RUNTIME, artifacts=ARTIFACTS, packages=PACKAGES))
            final = parent / staging.name.removeprefix('.')
            staging.rename(final)
            staging = final
            value = installation(final)
            atomic_json(status, dict(state='installing', phase='verifying'))
            check(value, root, environment)
            staging = None
            atomic_json(active, value)
        atomic_json(status, dict(state='ready', phase='ready', installation=value))
        return 0
    except Exception as error:
        atomic_json(status, dict(state='failed', phase='failed', message=str(error)))
        return 1
    finally:
        if staging is not None and staging.exists():
            shutil.rmtree(staging)
        os.close(lock)


if __name__ == '__main__':
    def interrupted(_signal, _frame):
        raise InstallationInterrupted('安装已中断')

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    raise SystemExit(main())
