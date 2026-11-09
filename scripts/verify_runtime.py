#!/usr/bin/env python3
"""Verify the shipped runtime, including execution after moving the App."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import os


def output(*args, env=None):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT, env=env, timeout=60)


def verify(app):
    app = app.resolve()
    metadata = app / "Contents/Resources/Runtime"
    manifest = json.loads((metadata / "engine-manifest.json").read_text())
    paths = [app / item["path"] for item in manifest["files"]]
    assert app / "Contents/Helpers/llama-server" in paths
    assert not list(app.rglob("*.gguf")), "Model weights must not be bundled"
    for item, path in zip(manifest["files"], paths):
        assert path.is_file() and app in path.resolve().parents, "Runtime file is missing or outside the App"
        assert path.stat().st_size == item["bytes"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"], "Runtime changed after signing"
        output("codesign", "--verify", "--strict", path)
        dependencies = output("otool", "-L", path).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(" (compatibility", 1)[0]
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency.startswith("@rpath/"):
                # The install ID is not a load dependency.
                assert dependency == "@rpath/" + path.name
                continue
            if dependency.startswith("@executable_path/"):
                resolved = (app / "Contents/Helpers" / dependency.removeprefix("@executable_path/")).resolve()
            elif dependency.startswith("@loader_path/"):
                resolved = (path.parent / dependency.removeprefix("@loader_path/")).resolve()
            else:
                raise AssertionError("External runtime dependency: " + dependency)
            assert resolved.is_file() and app in resolved.parents
    for name in ["llama.cpp-LICENSE.txt", "ThirdPartyNotices.txt", "SOURCES.txt", "llama-release.json"]:
        assert (metadata / name).stat().st_size > 0
    output("codesign", "--verify", "--deep", "--strict", app)
    if manifest["architecture"] == platform.machine():
        with tempfile.TemporaryDirectory(prefix="Yomitoki Runtime QA ") as scratch:
            moved = Path(scratch) / "Moved App.app"
            shutil.copytree(app, moved, symlinks=True)
            executable = moved / "Contents/Helpers/llama-server"
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith(("DYLD_", "GGML_", "LLAMA_"))}
            environment["PATH"] = "/usr/bin:/bin"
            version = output(executable, "--version", env=environment)
            assert "build " + manifest["version"].removeprefix("b") in version
            devices = output(executable, "--list-devices", env=environment)
            print(version.strip())
            print(devices.strip())
    total = sum(path.stat().st_size for path in paths)
    print("Passed bundled runtime checks: relocation, dependency closure, signatures, licenses, architecture and no bundled weights.")
    print("Runtime: " + str(round(total / 1024 / 1024, 1)) + " MiB in " + str(len(paths)) + " files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path, nargs="?", default=Path(__file__).resolve().parents[1] / "dist/读解.app")
    verify(parser.parse_args().app)
