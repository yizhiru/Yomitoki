#!/usr/bin/env python3
"""Prepare pinned reading data and a minimal Windows CPU runtime; no model weights."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build/data"
OUTPUT = ROOT / "desktop/.build/resources"
DICTIONARY_SHA = "809d104fe3c1e0ab328ff265bdc52b5eed1f9b669088fd199ef4e713812958a3"
ENGINE_SHA = "2a48f973521cb76fdf8123b12c62a89ad59b01372b98405123dd4e7114e1ae27"
ENGINE_ASSET = "llama-b12097-bin-win-cpu-x64.zip"


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1048576), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def download(url, target, expected):
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_suffix(".download")
        try:
            # curl handles redirects/retries consistently on Windows and macOS.
            subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20",
                            "--max-time", "600", "--output", str(partial), url], check=True)
            if digest(partial) != expected:
                raise RuntimeError("Checksum mismatch: " + target.name)
            partial.replace(target)
        finally:
            partial.unlink(missing_ok=True)
    if digest(target) != expected:
        raise RuntimeError("Checksum mismatch: " + target.name)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    database = CACHE / ("jmdict-" + DICTIONARY_SHA + ".sqlite")
    if not database.exists():
        archive = CACHE / "jmdict.tgz"
        version = "3.6.2%2B20261026175559"
        download(f"https://github.com/scriptin/jmdict-simplified/releases/download/{version}/jmdict-eng-{version}.json.tgz", archive, DICTIONARY_SHA)
        subprocess.run([sys.executable, str(ROOT / "scripts/build_dictionary.py"), str(archive), str(database)], check=True)
    shutil.copyfile(database, OUTPUT / "jmdict.sqlite")
    shutil.copyfile(ROOT / "Resources/zh.tsv", OUTPUT / "zh.tsv")
    shutil.copyfile(ROOT / "Resources/AppIcon.png", OUTPUT / "AppIcon.png")
    shutil.copytree(ROOT / "Resources/Dictionary", OUTPUT / "Dictionary", dirs_exist_ok=True)
    runtime = OUTPUT / "runtime"
    runtime.mkdir(exist_ok=True)
    archive = ROOT / ".build/runtime" / ENGINE_ASSET
    download("https://github.com/ggml-org/llama.cpp/releases/download/b12097/" + ENGINE_ASSET, archive, ENGINE_SHA)
    seen = set()
    with zipfile.ZipFile(archive) as source:
        for item in source.infolist():
            name = PurePosixPath(item.filename)
            if name.is_absolute() or ".." in name.parts:
                raise RuntimeError("Unsafe archive member")
            if name.suffix.lower() != ".dll" and name.name != "llama-server.exe":
                continue
            if name.name.lower() in seen:
                raise RuntimeError("Duplicate runtime filename: " + name.name)
            seen.add(name.name.lower())
            with source.open(item) as incoming, (runtime / name.name).open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
    if "llama-server.exe" not in seen:
        raise RuntimeError("Missing Windows translation engine")
    shutil.copyfile(ROOT / "Resources/Runtime/ThirdPartyNotices.txt", runtime / "ThirdPartyNotices.txt")
    licence = runtime / "llama.cpp-LICENSE.txt"
    with urllib.request.urlopen("https://raw.githubusercontent.com/ggml-org/llama.cpp/b97627967/LICENSE", timeout=60) as incoming:
        licence.write_bytes(incoming.read())
    manifest = {"version": "b12097", "architecture": "x64", "source": "https://github.com/ggml-org/llama.cpp/releases/tag/b12097",
                "archiveSHA256": ENGINE_SHA, "files": [{"path": path.name, "sha256": digest(path)}
                    for path in sorted(runtime.iterdir()) if path.suffix.lower() in (".exe", ".dll")]}
    (runtime / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print("Prepared dictionary and Windows CPU engine; no model weights.")


if __name__ == "__main__":
    main()
