#!/usr/bin/env python3
"""Real local Metal/process regression using authored fixtures, never user scans."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import struct
import subprocess
import sys
import time
import uuid
import zlib
import re
import shutil
import tempfile


def png(path, width=32, height=32):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    raw = b''.join(b'\0' + bytes(channel for x in range(width)
                                  for channel in ((x * 7 + y * 3) % 256, (y * 7 + x * 3) % 256, 128))
                   for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', width, height, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def wait_status(process, workspace, predicate, seconds=30):
    deadline = time.monotonic() + seconds
    latest = None
    while time.monotonic() < deadline:
        try:
            latest = json.loads((workspace / 'status.json').read_text())
            if predicate(latest):
                return latest
        except FileNotFoundError:
            pass
        if process.poll() is not None:
            raise AssertionError(f'Worker exited {process.returncode} before expected state: {latest}')
        time.sleep(.01)
    raise AssertionError(f'Worker timed out: {latest}')


def command(workspace, action):
    identifier = str(uuid.uuid4())
    # One append operation contains a complete control line.
    data = (json.dumps({'command': action, 'commandID': identifier}) + '\n').encode()
    descriptor = os.open(workspace / 'control.ndjson', os.O_WRONLY | os.O_APPEND)
    try:
        assert os.write(descriptor, data) == len(data)
    finally:
        os.close(descriptor)
    return identifier


def acceptance(executable, metallib, root):
    executable, metallib, root = map(lambda value: Path(value).resolve(), (executable, metallib, root))
    root.mkdir(parents=True, exist_ok=False)
    dataset = root / 'authored-dataset'
    images = dataset / 'images'
    images.mkdir(parents=True)
    records = ''
    for index in range(1, 4):
        png(images / f'frame-{index}.png')
        records += f'{index} 1 0 0 0 {(index - 2) * .08} 0 2 1 frame-{index}.png\n\n'
    (dataset / 'cameras.txt').write_text('1 PINHOLE 32 32 28 28 16 16\n')
    (dataset / 'images.txt').write_text(records)
    (dataset / 'points3D.txt').write_text(''.join(
        f'{index + 1} {(index % 16 - 8) * .0125} {(index // 16 - 8) * .0125} 0 128 128 128 0\n'
        for index in range(256)))
    source_hashes = {str(path.relative_to(dataset)): hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in dataset.rglob('*') if path.is_file()}

    def configuration(name, **extra):
        workspace = root / name
        data = dict(schemaVersion=1, jobID=str(uuid.uuid4()), datasetPath=str(dataset), workspacePath=str(workspace),
                    metallibPath=str(metallib), targetIterations=1_000_000, downscale=1,
                    checkpointIntervalSeconds=30, progressIntervalSeconds=.02)
        data.update(extra)
        config = root / (name + '.json')
        config.write_text(json.dumps(data))
        return workspace, config

    opened = []
    processes = []

    def start(config, pipe=False):
        log = open(root / (config.stem + '-' + str(len(processes)) + '.log'), 'wb')
        opened.append(log)
        process = subprocess.Popen([str(executable), '--config', str(config)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE if pipe else log, stderr=log)
        processes.append(process)
        return process

    try:
        workspace, config = configuration('durable')
        process = start(config, pipe=True)
        running = wait_status(process, workspace, lambda state: state['phase'] == 'running' and state['iteration'] >= 3)
        # Reproduce an app closing both pipes: the worker keeps its own state.
        process.stdin.close()
        process.stdout.close()
        continued = wait_status(process, workspace, lambda state: state['iteration'] >= running['iteration'] + 10)
        pause_id = command(workspace, 'pause')
        paused = wait_status(process, workspace, lambda state: state['phase'] == 'paused' and state.get('commandID') == pause_id)
        assert Path(paused['checkpointPath']).stat().st_size > 0
        time.sleep(.25)
        assert json.loads((workspace / 'status.json').read_text())['iteration'] == paused['iteration']
        duplicate = subprocess.run([str(executable), '--config', str(config)], stdin=subprocess.DEVNULL,
                                   capture_output=True, timeout=10)
        assert duplicate.returncode != 0 and b'Otra sesi' in duplicate.stderr
        assert json.loads((workspace / 'status.json').read_text())['pid'] == process.pid
        # A paused worker holds no engine; forced process loss must preserve that pause/checkpoint.
        process.kill()
        process.wait(timeout=10)
        recovered = start(config)
        restored = wait_status(recovered, workspace, lambda state: state['phase'] == 'paused' and state['pid'] == recovered.pid)
        assert restored['iteration'] == paused['iteration']
        command(workspace, 'resume')
        resumed = wait_status(recovered, workspace, lambda state: state['phase'] == 'running' and state['iteration'] >= restored['iteration'] + 5)
        checkpoint_id = command(workspace, 'checkpoint')
        saved = wait_status(recovered, workspace, lambda state: state.get('commandID') == checkpoint_id and state.get('commandState') == 'completed')
        assert saved['checkpointStep'] >= resumed['iteration']
        command(workspace, 'export')
        exported = wait_status(recovered, workspace, lambda state: state['phase'] == 'completed')
        assert recovered.wait(timeout=10) == 0
        package = Path(exported['resultPath'])
        for name in ('gaussianas.ply', 'gaussianas.splat', 'entrenamiento.ckpt', 'gaussianas.json'):
            assert (package / name).stat().st_size > 0
        metadata = json.loads((package / 'gaussianas.json').read_text())
        assert metadata['steps'] == exported['iteration'] and metadata['downscaleFactor'] == 1

        workspace2, config2 = configuration('paused-cancel', initiallyPaused=True)
        cancellation = start(config2)
        wait_status(cancellation, workspace2, lambda state: state['phase'] == 'paused')
        command(workspace2, 'checkpoint')
        wait_status(cancellation, workspace2, lambda state: state['phase'] == 'paused' and 'checkpointPath' in state)
        cancellation.stdin.write((json.dumps({'command': 'resume', 'commandID': str(uuid.uuid4())}) + '\n').encode())
        cancellation.stdin.flush()
        wait_status(cancellation, workspace2, lambda state: state['iteration'] >= 5)
        cancellation.stdin.write((json.dumps({'command': 'cancel', 'commandID': str(uuid.uuid4())}) + '\n').encode())
        cancellation.stdin.flush()
        cancelled = wait_status(cancellation, workspace2, lambda state: state['phase'] == 'cancelled')
        assert cancellation.wait(timeout=10) == 130 and Path(cancelled['checkpointPath']).stat().st_size > 0

        workspace3, config3 = configuration('signal-cancel')
        signalled = start(config3)
        wait_status(signalled, workspace3, lambda state: state['iteration'] >= 3)
        signalled.send_signal(signal.SIGTERM)
        signal_state = wait_status(signalled, workspace3, lambda state: state['phase'] == 'cancelled')
        assert signalled.wait(timeout=10) == 130 and Path(signal_state['checkpointPath']).stat().st_size > 0
        assert all(hashlib.sha256((dataset / path).read_bytes()).hexdigest() == digest for path, digest in source_hashes.items())
        evidence = {'status': 'passed', 'fixture': 'Authored 32x32 PNGs and 256 seed points; no user scan',
                    'continuedAfterBothPipesClosed': continued['iteration'] > running['iteration'],
                    'pauseSavedCheckpointAndHeldIteration': True, 'duplicateWorkspaceRejected': True,
                    'relaunchPreservedManualPause': True, 'resumedAndSavedCheckpoint': True,
                    'exportedIteration': exported['iteration'], 'exportedFilesComplete': True,
                    'stdinCancelCheckpointExit130': True, 'signalCancelCheckpointExit130': True,
                    'initiallyPausedExplicitCheckpoint': True, 'sourceSHA256Unchanged': True,
                    'control': ['stdin NDJSON', 'durable append-only NDJSON'], 'networkUsed': False}
        (root / 'verification.json').write_text(json.dumps(evidence, indent=2) + '\n')
        print(json.dumps(evidence, indent=2))
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
        for file in opened:
            file.close()


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def unsigned_macho_digest(path):
    # Xcode legitimately re-signs the copied helper. Normalize a temporary copy
    # only; never remove a signature from a build artifact or packaged child.
    with tempfile.TemporaryDirectory(prefix='forma-worker-signature-') as directory:
        copy = Path(directory) / 'FormaGaussianWorker'
        shutil.copy2(path, copy)
        result = subprocess.run(['/usr/bin/codesign', '--remove-signature', str(copy)],
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise ValueError('Cannot normalize signed Mac helper: ' + result.stderr.strip())
        return digest(copy)


def source_state(repo):
    vendor = repo / 'Vendor/Msplat'
    paths = [vendor / 'CMakeLists.txt', repo / 'Tools/FormaGaussianWorker.mm',
             repo / 'Tools/build_gaussian_worker.sh', repo / 'Tools/verify_gaussian_worker.py']
    paths += [path for path in (vendor / 'core').rglob('*')
              if path.is_file() and path.suffix in {'.h', '.hpp', '.cpp', '.mm', '.metal'}]
    hashes = {str(path.relative_to(repo)): digest(path) for path in sorted(paths)}
    fingerprint = hashlib.sha256()
    for path, sha256 in hashes.items():
        fingerprint.update(path.encode() + b'\0')
        fingerprint.update(bytes.fromhex(sha256))
    header = (vendor / 'core/include/forma_shader_abi.h').read_text()
    abi = re.search(r'#define\s+FORMA_MSPLAT_RUNTIME_ABI\s+(\d+)u?', header)
    if abi is None:
        raise ValueError('Missing native Metal ABI version.')
    return hashes, fingerprint.hexdigest(), int(abi.group(1))


def verify_artifacts(repo, output, record=False, app=None):
    output = output.resolve()
    paths = {name: output / name for name in ('FormaGaussianWorker', 'msplat-macos.metallib')}
    if not os.access(paths['FormaGaussianWorker'], os.X_OK):
        raise ValueError('Worker is missing or not executable. Run Tools/build_gaussian_worker.sh.')
    artifacts = {name: digest(path) for name, path in paths.items()}
    # The published Metal library must be the exact result of this native build.
    native_library = output / 'native/default.metallib'
    archive = output / 'native/libmsplat_core.a'
    if digest(native_library) != artifacts['msplat-macos.metallib']:
        raise ValueError('Published worker Metal library is stale. Run Tools/build_gaussian_worker.sh.')
    sources, fingerprint, abi = source_state(repo)
    current = dict(schemaVersion=1, platform='macOS', architectures=['arm64'], minimumMacOS='15.0',
                   runtimeABI=abi, sourceFingerprint=fingerprint, sourceSHA256=sources,
                   sha256=artifacts, nativeArchiveSHA256=digest(archive),
                   unsignedWorkerSHA256=unsigned_macho_digest(paths['FormaGaussianWorker']))
    manifest_path = output / 'worker-artifacts.json'
    if record:
        if app is not None:
            raise ValueError('Record the build output first; --app only verifies packaged artifacts.')
        pending = manifest_path.with_suffix('.pending')
        pending.write_text(json.dumps(current, indent=2, sort_keys=True) + '\n')
        pending.replace(manifest_path)
    else:
        recorded = json.loads(manifest_path.read_text())
        if recorded != current:
            raise ValueError('Gaussian worker sources/artifacts changed. Run Tools/build_gaussian_worker.sh before rebuilding the Mac app.')
    if app is not None:
        contents = app.resolve() / 'Contents'
        packaged = {'FormaGaussianWorker': contents / 'Helpers/FormaGaussianWorker',
                    'msplat-macos.metallib': contents / 'Resources/msplat-macos.metallib'}
        for name, path in packaged.items():
            actual = unsigned_macho_digest(path) if name == 'FormaGaussianWorker' else digest(path)
            expected = current['unsignedWorkerSHA256'] if name == 'FormaGaussianWorker' else artifacts[name]
            if actual != expected:
                raise ValueError('The Mac app contains a stale packaged ' + name + '. Rebuild Forma Desktop.')
        bundled_manifest = contents / 'Resources/worker-artifacts.json'
        if digest(bundled_manifest) != digest(manifest_path):
            raise ValueError('The Mac app contains a stale worker-artifacts.json. Rebuild Forma Desktop.')
    return current


def main():
    parser = argparse.ArgumentParser(description='Verify matching Mac Gaussian worker artifacts, or run a real Metal/process regression.')
    parser.add_argument('--record', action='store_true', help='Record artifacts after a successful helper build/sign.')
    parser.add_argument('--output', type=Path, help='Helper build output (default: build/GaussianDesktopWorker).')
    parser.add_argument('--app', type=Path, help='Also verify Helpers/Resources inside this .app bundle.')
    parser.add_argument('worker', nargs='?', type=Path)
    parser.add_argument('metallib', nargs='?', type=Path)
    parser.add_argument('owned_test_output', nargs='?', type=Path)
    arguments = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    try:
        if any((arguments.worker, arguments.metallib, arguments.owned_test_output)):
            if not all((arguments.worker, arguments.metallib, arguments.owned_test_output)) or any((arguments.record, arguments.output, arguments.app)):
                parser.error('Metal acceptance requires WORKER METALLIB OWNED_TEST_OUTPUT, without artifact-verification options.')
            acceptance(arguments.worker, arguments.metallib, arguments.owned_test_output)
        else:
            verify_artifacts(repo, arguments.output or repo / 'build/GaussianDesktopWorker', arguments.record, arguments.app)
            print('Forma Gaussian Mac worker, native sources and Metal library match.')
    except (OSError, ValueError, KeyError, AssertionError) as error:
        parser.exit(1, 'error: Forma Gaussian Mac worker verification: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
