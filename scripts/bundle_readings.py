"""Freeze the pinned offline reader in an isolated build environment."""
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PINS = ['sudachipy==0.7.0','sudachidict_core==20261015','pyinstaller==6.22.3']

def bundle(target):
    source = ROOT/'Resources/Readings/sudachi_reader.py'
    cache = ROOT/'.build/reading-helper'/sys.platform/platform.machine()
    stamp = hashlib.sha256(source.read_bytes() + Path(__file__).read_bytes() + str(PINS).encode()).hexdigest()
    built = cache/'dist/sudachi-reader'
    exe = 'sudachi-reader.exe' if os.name == 'nt' else 'sudachi-reader'
    if not (built/exe).exists() or not (cache/'version').exists() or (cache/'version').read_text() != stamp:
        cache.mkdir(parents=True, exist_ok=True)
        python = os.environ.get('SUDACHI_BUILD_PYTHON')
        if not python:
            env = cache/'venv'
            subprocess.run([sys.executable,'-m','venv',str(env)],check=True)
            python = str(env/('Scripts/python.exe' if os.name == 'nt' else 'bin/python'))
            subprocess.run([python,'-m','pip','install',*PINS],check=True)
        subprocess.run([python,'-c',"from importlib.metadata import version; import sys; assert all(version(p.split('==')[0]) == p.split('==')[1] for p in sys.argv[1:])",*PINS],check=True)
        subprocess.run([python,'-m','PyInstaller','--noconfirm','--onedir','--name','sudachi-reader',
                        '--collect-all','sudachipy','--collect-all','sudachidict_core',
                        '--copy-metadata','sudachipy','--copy-metadata','sudachidict_core',
                        str(source)],cwd=cache,check=True)
        smoke = subprocess.check_output([str(built/exe)], input='😀俺が注文する。'.encode(), timeout=45)
        assert json.loads(smoke)[0] == {'start':2, 'surface':'俺', 'kana':'おれ'}, 'Sudachi failed offline check'
        (cache/'version').write_text(stamp)
    destination = Path(target)/'sudachi-reader'
    if (destination/'build-id').is_file() and (destination/'build-id').read_text() == stamp and (destination/exe).is_file():
        return
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(built,destination,symlinks=True)
    (destination/'build-id').write_text(stamp)

if __name__ == '__main__':
    bundle(sys.argv[1])
