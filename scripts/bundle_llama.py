#!/usr/bin/env python3
"""Package only llama-server and its pinned, relocatable Mach-O dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT / "Resources/Runtime/llama-release.json"


def run(*args):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dependencies(path):
    lines = run("otool", "-L", path).splitlines()[1:]
    identity = run("otool", "-D", path).splitlines()[1:]
    identity = identity[0].strip() if identity else None
    return [line.strip().split(" (compatibility", 1)[0] for line in lines
            if line.strip().split(" (compatibility", 1)[0] != identity]


def is_system(path):
    return path.startswith(("/System/Library/", "/usr/lib/"))


def check_platform(path, architecture):
    architectures = run("lipo", "-archs", path).strip().split()
    if architecture not in architectures:
        raise RuntimeError("Wrong engine architecture: " + str(path))
    import re
    versions = re.findall(r"\bminos\s+(\d+(?:\.\d+)*)", run("vtool", "-show-build", path))
    if not versions or any(tuple(map(int, value.split("."))) > (14, 0, 0) for value in versions):
        raise RuntimeError("Engine requires newer than macOS 14: " + str(path))


def unpack(archive, destination):
    # Copy regular members only; materialize archive symlinks after validating
    # their targets, so no archive entry can write outside the scratch directory.
    with tarfile.open(archive, "r:gz") as source:
        links = []
        for member in source.getmembers():
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise RuntimeError("Unsafe archive member")
            target = destination.joinpath(*name.parts)
            if member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as incoming, target.open("wb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing)
                target.chmod(member.mode & 0o755)
            elif member.issym():
                links.append((target, member.linkname))
            elif not member.isdir():
                raise RuntimeError("Unsupported archive member: " + member.name)
        for target, link in links:
            resolved = (target.parent / link).resolve()
            if destination.resolve() not in resolved.parents:
                raise RuntimeError("Unsafe archive link: " + str(target))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(link)
        for target, _ in links:
            resolved = target.resolve(strict=True)
            if destination.resolve() not in resolved.parents or not resolved.is_file():
                raise RuntimeError("Unsafe or dangling archive link: " + str(target))


def bundle(app, architecture):
    release = json.loads(RELEASE.read_text())
    asset = release["architectures"][architecture]
    cache = ROOT / ".build/runtime"
    cache.mkdir(parents=True, exist_ok=True)
    archive = Path(os.environ.get("LLAMA_RUNTIME_ARCHIVE", str(cache / asset["asset"])))
    if not archive.exists():
        if "LLAMA_RUNTIME_ARCHIVE" in os.environ:
            raise RuntimeError("LLAMA_RUNTIME_ARCHIVE does not exist")
        partial = archive.with_suffix(archive.suffix + ".download")
        url = "https://github.com/ggml-org/llama.cpp/releases/download/" + release["version"] + "/" + asset["asset"]
        subprocess.check_call(["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "2",
                               "--connect-timeout", "15", "--max-time", "300", "--output", str(partial), url])
        if sha256(partial) != asset["sha256"]:
            partial.unlink()
            raise RuntimeError("Downloaded llama.cpp checksum mismatch")
        partial.replace(archive)
    if sha256(archive) != asset["sha256"]:
        raise RuntimeError("llama.cpp archive checksum mismatch: " + str(archive))

    helpers = app / "Contents/Helpers"
    libraries = app / "Contents/Frameworks/llama"
    notices = app / "Contents/Resources/Runtime"
    for folder in (helpers, libraries, notices):
        folder.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="llama-unpack-", dir=cache) as scratch:
        unpack(archive, Path(scratch))
        servers = list(Path(scratch).rglob("llama-server"))
        if len(servers) != 1:
            raise RuntimeError("Expected one llama-server")
        source_dir = servers[0].parent
        pending = [("llama-server", servers[0])]
        files = {}
        edges = {}
        while pending:
            name, source = pending.pop()
            if name in files:
                continue
            target = (helpers if name == "llama-server" else libraries) / name
            shutil.copyfile(source.resolve(), target)
            target.chmod(0o755)
            check_platform(target, architecture)
            files[name] = target
            edges[name] = dependencies(source)
            for dependency in edges[name]:
                if is_system(dependency):
                    continue
                basename = Path(dependency).name
                candidate = source_dir / basename
                if not candidate.is_file():
                    raise RuntimeError("Unbundled dependency: " + dependency)
                pending.append((basename, candidate))

        for name, target in files.items():
            for dependency in edges[name]:
                if is_system(dependency):
                    continue
                basename = Path(dependency).name
                replacement = ("@executable_path/../Frameworks/llama/" if name == "llama-server" else "@loader_path/") + basename
                run("install_name_tool", "-change", dependency, replacement, target)
            if name != "llama-server":
                run("install_name_tool", "-id", "@rpath/" + name, target)
            # All bundled dependencies now have direct relative paths. Remove
            # the upstream build's search paths rather than depending on them.
            import re
            paths = re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset", run("otool", "-l", target))
            for path in dict.fromkeys(paths):
                run("install_name_tool", "-delete_rpath", path, target)
            for dependency in dependencies(target):
                if not is_system(dependency) and not dependency.startswith(("@loader_path/", "@executable_path/")):
                    raise RuntimeError("Nonrelocatable dependency: " + dependency)

        shutil.copyfile(source_dir / "LICENSE", notices / "llama.cpp-LICENSE.txt")
        shutil.copyfile(RELEASE, notices / "llama-release.json")
        shutil.copyfile(ROOT / "Resources/Runtime/ThirdPartyNotices.txt", notices / "ThirdPartyNotices.txt")
        (notices / "SOURCES.txt").write_text(
            "llama.cpp " + release["version"] + "\n" + release["source"] + "\nArchive SHA-256: " + asset["sha256"]
            + "\nOnly llama-server and its transitive runtime libraries are included. Model weights are not included.\n")

    identity = os.environ.get("CODE_SIGN_IDENTITY", "-")
    for path in sorted(libraries.iterdir()):
        run("codesign", "--force", "--sign", identity, path)
    run("codesign", "--force", "--sign", identity, helpers / "llama-server")
    manifest = {"version": release["version"], "architecture": architecture, "files": [
        {"path": str(path.relative_to(app)), "bytes": path.stat().st_size, "sha256": sha256(path)}
        for path in sorted(files.values())]}
    (notices / "engine-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    total = sum(path.stat().st_size for path in files.values())
    print("已内置 llama.cpp " + release["version"] + " (" + architecture + "), " + str(len(files))
          + " 个运行文件，" + str(round(total / 1024 / 1024, 1)) + " MiB")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--arch", choices=["arm64", "x86_64"], required=True)
    args = parser.parse_args()
    bundle(args.app, args.arch)
