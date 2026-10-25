#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile


RESOURCES = Path(__file__).resolve().parent


def absolute_path(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise argparse.ArgumentTypeError("必须使用绝对路径")
    return path


def run(arguments: list[str], environment: dict[str, str]) -> str:
    child = subprocess.Popen(arguments, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        output, errors = child.communicate()
        if child.returncode:
            detail = (errors or output).strip()[-4000:]
            raise RuntimeError(f"安装命令失败（{Path(arguments[0]).name}，{child.returncode}）：{detail}")
        return output
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(4 * 1024 * 1024):
            result.update(block)
    return result.hexdigest()


def directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"安装路径必须为普通目录：{path}")


def write_json(path: Path, value: dict) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, ensure_ascii=False, allow_nan=False, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def runtime_check(python: Path, requirements: str, environment: dict[str, str], version: str) -> None:
    pinned = dict(re.findall(r"^([\w.-]+)==([^\s\\]+)", requirements, re.MULTILINE))
    source = re.search(r"^moss-transcribe-diarize @ git\+(.+)@([a-f0-9]{40})$", requirements, re.MULTILINE)
    if not source or not pinned:
        raise ValueError("依赖锁缺少固定版本或 MOSS 源提交")
    code = '''
import importlib.metadata as metadata, json, platform, sys
expected, source, commit, version = json.loads(sys.argv[1])
if platform.python_version() != version:
    raise RuntimeError("Python version does not match lock")
for name, value in expected.items():
    if metadata.version(name) != value:
        raise RuntimeError("Package does not match lock: " + name)
distribution = metadata.distribution("moss-transcribe-diarize")
direct = json.loads(distribution.read_text("direct_url.json") or "{}")
if direct.get("url") != source or direct.get("vcs_info", {}).get("commit_id") != commit:
    raise RuntimeError("MOSS source does not match lock")
'''
    run([str(python), "-I", "-B", "-c", code, json.dumps([pinned, source[1], source[2], version])], environment)


def prepare_runtime(root: Path, uv: Path, lock: dict, environment: dict[str, str]) -> Path:
    requirements = (RESOURCES / lock["requirements_lock"]).read_text(encoding="utf-8")
    lock_hash = hashlib.sha256(requirements.encode()).hexdigest()
    parent = root / "runtimes"
    directory(parent)
    final = parent / f"{lock['runtime_version']}-{lock_hash[:12]}"
    expected = {"runtimeVersion": lock["runtime_version"], "requirementsSHA256": lock_hash, "pythonVersion": lock["python"]}
    if final.exists() or final.is_symlink():
        if final.is_symlink() or json.loads((final / "installation.json").read_text()) != expected:
            raise ValueError(f"既有运行时未通过完整性检查，请使用新的安装目录：{final}")
        runtime_check(final / "bin/python", requirements, environment, lock["python"])
        return final / "bin/python"
    run([str(uv), "--no-config", "python", "install", "--no-bin", lock["python"]], environment)
    staging = Path(tempfile.mkdtemp(prefix=".runtime-", dir=parent))
    try:
        run([str(uv), "--no-config", "venv", "--managed-python", "--python", lock["python"], "--relocatable", str(staging)], environment)
        python = staging / "bin/python"
        source_lines = [line for line in requirements.splitlines() if line.startswith("moss-transcribe-diarize @ ")]
        if len(source_lines) != 1:
            raise ValueError("依赖锁必须恰好包含一个固定 MOSS 源提交")
        hashed = staging / "requirements.hashed.txt"
        hashed.write_text("\n".join(line for line in requirements.splitlines() if line not in source_lines) + "\n")
        run([str(uv), "--no-config", "pip", "sync", "--python", str(python), "--require-hashes", "--only-binary", ":all:", str(hashed)], environment)
        run([str(uv), "--no-config", "pip", "install", "--python", str(python), "--no-deps", "--no-build-isolation", source_lines[0]], environment)
        run([str(uv), "--no-config", "pip", "check", "--python", str(python)], environment)
        runtime_check(python, requirements, environment, lock["python"])
        hashed.unlink()
        write_json(staging / "installation.json", expected)
        staging.rename(final)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    runtime_check(final / "bin/python", requirements, environment, lock["python"])
    return final / "bin/python"


def model_files(path: Path) -> dict[str, dict]:
    files = {}
    for candidate in sorted(path.rglob("*")):
        relative = candidate.relative_to(path)
        if ".cache" in relative.parts or relative.name == "installation.json":
            continue
        if candidate.is_symlink():
            raise ValueError(f"模型快照不能包含符号链接：{relative}")
        if candidate.is_file():
            files[relative.as_posix()] = {"size": candidate.stat().st_size, "sha256": digest(candidate)}
    if not all(name in files for name in ("config.json", "tokenizer_config.json", "preprocessor_config.json")):
        raise ValueError("模型快照缺少配置或分词器")
    weights = [name for name in files if name.endswith(".safetensors")]
    if not weights or any(files[name]["size"] < 8 for name in weights):
        raise ValueError("模型快照缺少有效权重")
    index = path / "model.safetensors.index.json"
    if index.is_file():
        weight_map = json.loads(index.read_text())["weight_map"]
        if not weight_map or not set(weight_map.values()).issubset(files):
            raise ValueError("模型分片索引引用了缺失文件")
    return files


def prepare_model(root: Path, python: Path, spec: dict, environment: dict[str, str]) -> Path:
    parent = root / "models" / spec["repo"].replace("/", "--")
    directory(root / "models")
    directory(parent)
    final = parent / spec["revision"]
    expected = {"repository": spec["repo"], "revision": spec["revision"]}
    if final.exists() or final.is_symlink():
        if final.is_symlink():
            raise ValueError("既有模型不能为符号链接")
        manifest = json.loads((final / "installation.json").read_text())
        if any(manifest.get(key) != value for key, value in expected.items()) or manifest.get("files") != model_files(final):
            raise ValueError(f"既有模型未通过完整性检查，请使用新的安装目录：{final}")
        return final
    staging = Path(tempfile.mkdtemp(prefix=".model-", dir=parent))
    code = "from huggingface_hub import snapshot_download; import sys; snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3])"
    try:
        run([str(python), "-I", "-B", "-c", code, spec["repo"], spec["revision"], str(staging)], environment)
        write_json(staging / "installation.json", {**expected, "files": model_files(staging)})
        staging.rename(final)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return final


def main() -> int:
    parser = argparse.ArgumentParser(description="在指定目录安装固定版本的本地转写运行时和单个模型；由 MeetingTape smoke 成功后激活。")
    parser.add_argument("--model-type", choices=("qwen", "moss"), required=True)
    parser.add_argument("--profile", choices=("low-memory", "standard"), required=True)
    parser.add_argument("--root", type=absolute_path, required=True)
    parser.add_argument("--uv", type=absolute_path, required=True)
    parser.add_argument("--output", type=absolute_path, required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("本地转写仅支持 Apple Silicon macOS")
    if not args.uv.is_file() or not os.access(args.uv, os.X_OK):
        raise ValueError("uv 不是可执行文件")
    if args.root == Path(args.root.anchor):
        raise ValueError("安装根目录必须为专用目录")
    directory(args.root)
    root = args.root.resolve()
    lock = json.loads((RESOURCES / "models.lock.json").read_text())
    environment = {key: value for key, value in os.environ.items() if not key.startswith(("UV_", "PIP_", "PYTHON", "HF_", "HUGGINGFACE_", "TRANSFORMERS_"))}
    environment.update({
        "UV_PYTHON_INSTALL_DIR": str(root / "python"), "UV_CACHE_DIR": str(root / "cache/uv"),
        "UV_NO_PROGRESS": "1", "HF_HOME": str(root / "cache/huggingface"),
        "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1",
    })
    descriptor = os.open(root / "bootstrap.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        python = prepare_runtime(root, args.uv, lock, environment)
        spec = lock["profiles"][args.profile][args.model_type]
        model = prepare_model(root, python, spec, environment)
        write_json(args.output, {
            "schemaVersion": 1, "family": args.model_type, "profile": args.profile,
            "python": str(python), "model": str(model), "revision": spec["revision"],
            "repository": spec["repo"], "runtimeVersion": lock["runtime_version"],
        })
    finally:
        os.close(descriptor)
    return 0


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise RuntimeError("安装已中断")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"本地模型安装失败：{error}", file=sys.stderr)
        raise SystemExit(1)
