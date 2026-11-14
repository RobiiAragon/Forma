#!/usr/bin/env python3
"""Reject stale native libraries or Metal resources before building/shipping Forma."""
import argparse
import hashlib
import json
from pathlib import Path


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def source_fingerprint(root):
    vendor = root / 'Vendor/Msplat'
    paths = [vendor / 'CMakeLists.txt', root / 'scripts/build_msplat.sh']
    paths += [p for p in (vendor / 'core').rglob('*')
              if p.is_file() and p.suffix in {'.h', '.hpp', '.cpp', '.mm', '.metal'}]
    value = hashlib.sha256()
    for path in sorted(paths):
        value.update(str(path.relative_to(root)).encode() + b'\0')
        value.update(bytes.fromhex(digest(path)))
    return value.hexdigest()


def verify(root, record=False, app=None):
    build = root / 'Vendor/Msplat/Build'
    manifest_path = build / 'forma-artifacts.json'
    names = ['msplat-ios.metallib', 'msplat-simulator.metallib']
    archives = sorted((build / 'MsplatCore.xcframework').rglob('libmsplat_core.a'))
    if len(archives) != 2:
        raise ValueError('Expected device and simulator native archives. Run scripts/build_msplat.sh.')
    paths = [build / name for name in names] + archives
    current = {str(path.relative_to(root)): digest(path) for path in paths}
    for name in names:
        if digest(root / 'Forma/Resources' / name) != digest(build / name):
            raise ValueError('Stale Forma/Resources/' + name + '. Run scripts/build_msplat.sh.')
    fingerprint = source_fingerprint(root)
    if record:
        manifest = {'sourceFingerprint': fingerprint, 'sha256': current}
        pending = manifest_path.with_suffix('.pending')
        pending.write_text(json.dumps(manifest, indent=2) + '\n')
        pending.replace(manifest_path)
    else:
        manifest = json.loads(manifest_path.read_text())
        if manifest['sourceFingerprint'] != fingerprint or manifest['sha256'] != current:
            raise ValueError('Native sources/artifacts changed. Run scripts/build_msplat.sh.')
    if app:
        for name in names:
            if digest(app / name) != digest(build / name):
                raise ValueError('Built app contains stale ' + name + '. Rebuild Forma.')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', action='store_true')
    parser.add_argument('--app', type=Path)
    arguments = parser.parse_args()
    try:
        verify(Path(__file__).resolve().parent.parent, arguments.record, arguments.app)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, 'error: Forma native Metal verification: ' + str(error) + '\n')
    print('Forma native libraries and Metal resources match.')
