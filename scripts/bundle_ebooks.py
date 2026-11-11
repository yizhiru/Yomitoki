#!/usr/bin/env python3
"""Bundle the shared, pinned Windows/macOS text parser without a Node dependency."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]

def bundle(app):
    source = ROOT / "desktop/src"
    target = app / "Contents/Resources/Ebook"
    manifest = json.loads((source / "vendor/manifest.json").read_text())
    for name, expected in manifest["files"].items():
        assert hashlib.sha256((source / "vendor" / name).read_bytes()).hexdigest() == expected, name
    target.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source / "vendor", target / "vendor", dirs_exist_ok=True)
    worker = target / "ebook-import"
    worker.mkdir(exist_ok=True)
    for name in ["worker.mjs", "zip.mjs", "text.mjs", "mdx.mjs", "yomitan.mjs"]:
        shutil.copy2(source / "ebook-import" / name, worker / name)
    for name in ["host.html", "compat.js"]:
        shutil.copy2(ROOT / "Resources/Ebook" / name, worker / name)
    files = {str(path.relative_to(target)): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in sorted(target.rglob("*")) if path.is_file() and path.name != "bundle-manifest.json"}
    (target / "bundle-manifest.json").write_text(json.dumps({"files": files}, indent=2) + "\n")
    print("Bundled Foliate EPUB/MOBI parser with verified upstream sources and licenses.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    bundle(parser.parse_args().app)
