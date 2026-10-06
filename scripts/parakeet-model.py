#!/usr/bin/env python3
"""Install and verify the reviewed Parakeet Core ML directory using only stdlib."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
CANONICAL_MANIFEST = ROOT / "TalkText/Sources/TalkText/Resources/parakeet-model.json"


def load_manifest(path):
    manifest = json.loads(Path(path).read_text())
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", manifest["repository"]):
        raise ValueError("invalid model repository")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["revision"]):
        raise ValueError("model revision must be an immutable commit")
    directory = manifest["directory"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", directory):
        raise ValueError("invalid model directory")
    files = manifest["files"]
    if not files or len({item["path"] for item in files}) != len(files):
        raise ValueError("empty or duplicate model file list")
    for item in files:
        name = PurePosixPath(item["path"])
        if name.is_absolute() or ".." in name.parts or str(name) != item["path"] or "\\" in item["path"]:
            raise ValueError("unsafe model file path")
        if not isinstance(item["size"], int) or item["size"] <= 0:
            raise ValueError("invalid model file size")
        if not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]):
            raise ValueError("invalid model file digest")
    return manifest


def verify_file(root, item):
    root = Path(root)
    path = root / item["path"]
    if not path.resolve().is_relative_to(root.resolve()) or path.is_symlink() or not path.is_file():
        raise ValueError(f"missing or unsafe model file: {item['path']}")
    if path.stat().st_size != item["size"]:
        raise ValueError(f"model file size mismatch: {item['path']}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != item["sha256"]:
        raise ValueError(f"model file digest mismatch: {item['path']}")


def verify(root, manifest):
    if not Path(root).is_dir():
        raise ValueError(f"model directory is missing: {root}")
    for item in manifest["files"]:
        verify_file(root, item)


def download_file(staging, manifest, item):
    path = Path(staging) / item["path"]
    path.parent.mkdir(parents=True, exist_ok=True)
    name = urllib.parse.quote(item["path"], safe="/")
    url = f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/{name}"
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "TalkText-model-setup/2"})
            with urllib.request.urlopen(request, timeout=120) as response, path.open("wb") as destination:
                total = 0
                for block in iter(lambda: response.read(1024 * 1024), b""):
                    total += len(block)
                    if total > item["size"]:
                        raise ValueError(f"download exceeds pinned size: {item['path']}")
                    destination.write(block)
            verify_file(staging, item)
            return
        except Exception:
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def install(destination, manifest, downloader=download_file):
    destination = Path(destination)
    try:
        verify(destination, manifest)
        print(f"Verified cached Parakeet model: {destination}")
        return
    except (OSError, ValueError):
        pass
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".parakeet-download-", dir=destination.parent))
    backup = None
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            jobs = [executor.submit(downloader, staging, manifest, item) for item in manifest["files"]]
            for job in concurrent.futures.as_completed(jobs):
                job.result()
        verify(staging, manifest)
        if destination.exists():
            backup = destination.with_name(destination.name + ".invalid." + uuid.uuid4().hex)
            destination.rename(backup)
        try:
            staging.rename(destination)
        except OSError:
            if backup is not None:
                backup.rename(destination)
            raise
        print(f"Installed verified Parakeet model: {destination}")
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["install-model", "verify-model", "model-name"])
    parser.add_argument("path", nargs="?")
    arguments = parser.parse_args()
    manifest = load_manifest(os.environ.get("TALKTEXT_MODEL_MANIFEST", str(CANONICAL_MANIFEST)))
    if arguments.command == "model-name":
        print(manifest["directory"])
        return
    destination = Path(arguments.path) if arguments.path else ROOT / "models" / manifest["directory"]
    if arguments.command == "install-model":
        install(destination, manifest)
    else:
        verify(destination, manifest)
        print(f"Verified Parakeet model: {destination}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
