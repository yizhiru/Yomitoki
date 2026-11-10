#!/usr/bin/env python3
"""Verify shared parser source, bundle integrity and required MIT notices."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def verify(app):
    root = app / "Contents/Resources/Ebook"
    manifest = json.loads((root / "bundle-manifest.json").read_text())
    expected_files = set(manifest["files"]) | {"bundle-manifest.json"}
    assert {str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()} == expected_files
    for name, digest in manifest["files"].items():
        bundled = (root / name).read_bytes()
        assert hashlib.sha256(bundled).hexdigest() == digest, name
        source = ROOT / "desktop/src" / name
        if name in ["ebook-import/host.html", "ebook-import/compat.js"]:
            source = ROOT / "Resources/Ebook" / Path(name).name
        assert bundled == source.read_bytes(), name
    upstream = json.loads((root / "vendor/manifest.json").read_text())
    for name, digest in upstream["files"].items():
        assert hashlib.sha256((root / "vendor" / name).read_bytes()).hexdigest() == digest, name
    for name in ["foliate/LICENSE", "fflate/LICENSE"]:
        assert "MIT" in (root / "vendor" / name).read_text()
    print("Passed bundled Foliate/fflate versions, source equality, checksums, file inventory and licenses.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path, nargs="?", default=ROOT / "dist/读解.app")
    verify(parser.parse_args().app)
