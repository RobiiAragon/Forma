#!/usr/bin/env python3
"""Evaluate a completed Forma Mac run without advancing training or changing its files."""
from pathlib import Path
import argparse
import array
import fcntl
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
EXPECTED_JOB = 'FAC12FBD-D8D3-471F-B107-558A10F3A58F'
EXPECTED_RUN = 'A26E5CCA-D562-4A4A-B094-E82EFA011213'
DEFAULT_RUN = Path.home() / 'Library/Application Support/FormaDesktop/Work' / ('Gaussian-' + EXPECTED_JOB) / 'runs' / EXPECTED_RUN
QUALITY = REPO / 'build/Research/GaussianQualityContinuation'
BASELINE = QUALITY / 'room-3000-to5000-horizon30000-pooled'
TERMINAL = QUALITY / 'room-3000-to5000-terminal3000-pooled'
HELPER_SHA = '372cf1ab1bbcd604363d0ff5fcd926e2e446aac05815d0890a9f7c96195ec68f'
SNAPSHOT = REPO / 'build/Research/GaussianRun30000EvaluationPreparation/frozen-runtime'
SNAPSHOT_SHA = '43dcc6a039966bd855b3b8c953989a09f76bbb93fe06aadd6e76869d4becbacc'
ORIGINAL_ARCHIVE_SHA = '3de09b4ec57f0f4458ed7f632a5aab028deb882d667abf13eb52711f3626d537'
VIEWS = [(0, 'C5E81472-7310-4B0E-A41A-3BF478679B1D'),
         (283, 'D57CBC28-36E2-41BA-AD2C-99B1AA8950B5'),
         (565, 'AF41061B-731E-419F-AB9E-36FF365E3A4C')]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def plan(run):
    config, status = read_json(run / 'config.json'), read_json(run / 'status.json')
    require(config['schemaVersion'] == 1 and config['jobID'] == EXPECTED_JOB, 'This evaluator is for the explicitly documented FAC12FBD room run.')
    require(run.name == EXPECTED_RUN and Path(config['workspacePath']).resolve() == run, 'Run/workspace identity mismatch.')
    require(config['targetIterations'] == 30000 and config['downscale'] == 1, 'Expected the full-resolution 30000-step policy.')
    require(status['jobID'] == config['jobID'] and Path(status['workspacePath']).resolve() == run, 'Status belongs to another run.')
    dataset = Path(config['datasetPath']).resolve()
    require(digest(dataset / 'dataset.json') == config['datasetIndexSHA256'], 'Dataset index changed since launch.')
    manifest = read_json(dataset / 'dataset.json')
    frames = sorted(manifest['frames'], key=lambda frame: frame['timestamp'])
    require(len(frames) == 566, 'This fixed-room comparison expects the original 566 observations, not a subset.')
    for index, identifier in VIEWS:
        require(frames[index]['id'] == identifier, 'An evaluation camera ID differs from the predeclared baseline.')
    return config, status, dataset, frames


def active_workers():
    # No signals, controls, polling loop or changes to any worker are performed.
    text = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
    return [line.strip() for line in text.splitlines() if Path(line.strip().split(maxsplit=1)[-1]).name == 'FormaGaussianWorker']


def dataset_inputs(dataset, frames):
    paths = {name: dataset / name for name in ('dataset.json', 'cameras.txt', 'images.txt', 'points3D.txt')}
    for frame in frames:
        relative = frame['rgbFile']
        path = (dataset / relative).resolve()
        require(path.is_relative_to(dataset) and path.is_file(), 'A source photograph leaves its dataset or is absent.')
        paths[relative] = path
    return paths


def finite_ply(path, expected_count):
    """Stream every exported float; preserve all SH3 coefficients and every Gaussian."""
    with Path(path).open('rb') as file:
        require(file.readline().strip() == b'ply', 'Not a PLY file.')
        names, count, format_name = [], None, None
        while True:
            line = file.readline()
            require(bool(line), 'Truncated PLY header.')
            fields = line.decode('ascii').strip().split()
            if fields[:1] == ['format']:
                format_name = fields[1:]
            elif fields[:2] == ['element', 'vertex']:
                count = int(fields[2])
            elif fields[:1] == ['property']:
                require(len(fields) == 3 and fields[1] == 'float', 'Unexpected PLY property; no conversion or truncation attempted.')
                names.append(fields[2])
            elif fields == ['end_header']:
                break
        expected = ['x', 'y', 'z', 'nx', 'ny', 'nz'] + ['f_dc_' + str(i) for i in range(3)]
        expected += ['f_rest_' + str(i) for i in range(45)]
        expected += ['opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3']
        require(format_name == ['binary_little_endian', '1.0'] and names == expected, 'Expected the complete native binary SH3 export layout.')
        require(count == expected_count and count > 0, 'PLY and checkpoint populations differ.')
        remaining, checked = count, 0
        while remaining:
            records = min(4096, remaining)  # Streaming block only, never a model population limit.
            block = file.read(records * len(names) * 4)
            require(len(block) == records * len(names) * 4, 'Truncated Gaussian PLY data.')
            floats = array.array('f'); floats.frombytes(block)
            if sys.byteorder != 'little':
                floats.byteswap()
            for offset, value in enumerate(floats):
                require(math.isfinite(value), f'Nonfinite PLY value at float {checked + offset}, property {names[(checked + offset) % len(names)]}.')
            checked += len(floats); remaining -= records
        require(not file.read(1), 'Unexpected PLY tail; no bytes were discarded.')
    return dict(splats=count, sphericalHarmonicsDegree=3, restCoefficientsPerGaussian=45,
                allExportedFloatsFinite=True, checkedFloatCount=checked, sha256=digest(path))


def evaluator_source():
    helper = REPO / 'Tools/benchmark_gaussian_continuation.mm'
    require(digest(helper) == HELPER_SHA, 'The original validated measurement helper changed; review it before comparing metrics.')
    prefix = helper.read_text().split('int main(int argc,char**argv)', 1)[0]
    body = r'''
int main(int argc,char**argv) {@autoreleasepool {
    MsplatDataset dataset=nullptr;MsplatTrainer trainer=nullptr;fs::path output;
    try {
        require(argc==7,"Usage: DATASET OWNED_CHECKPOINT MATCHING_METALLIB OWNED_OUTPUT HORIZON EXPECTED_STEP");
        fs::path source=fs::canonical(argv[1]),checkpoint=fs::canonical(argv[2]),metal=fs::canonical(argv[3]);output=fs::canonical(argv[4]);
        int horizon=std::stoi(argv[5]),expectedStep=std::stoi(argv[6]);require(horizon>0&&expectedStep>0,"Invalid evaluation horizon");
        auto state=checkCheckpoint(checkpoint);require([state[@"step"] intValue]==expectedStep,"Checkpoint step differs from completed run");
        json(output/"checkpoint-validation.json",state);
        InputData input=inputDataFromX(source.string());
        NSData* bytes=[NSData dataWithContentsOfFile:ns((source/"dataset.json").string())];
        NSDictionary* manifest=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
        NSArray* frames=[manifest[@"frames"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){return[a[@"timestamp"] compare:b[@"timestamp"]];}];
        require(frames.count==566,"Expected all 566 fixed-room frames");
        std::vector<Target> targets;
        const std::vector<std::pair<int,std::string>> wanted={{0,"C5E81472-7310-4B0E-A41A-3BF478679B1D"},{283,"D57CBC28-36E2-41BA-AD2C-99B1AA8950B5"},{565,"AF41061B-731E-419F-AB9E-36FF365E3A4C"}};
        for(auto& value:wanted){NSDictionary*frame=frames[value.first];require(value.second==std::string([frame[@"id"] UTF8String]),"Fixed camera ID changed");
            fs::path rgb=source/std::string([frame[@"rgbFile"] UTF8String]);int index=-1;
            for(size_t i=0;i<input.cameras.size();i++)if(fs::path(input.cameras[i].filePath).filename()==rgb.filename()){index=int(i);break;}
            require(index>=0,"Native camera missing");targets.push_back({index,value.first,value.second,rgb});}
        msplat_set_metallib_path(metal.c_str());dataset=msplat_dataset_create(source.c_str(),1,false,8);require(dataset,"Dataset creation failed");
        auto config=msplat_default_config();config.iterations=horizon;config.stopDensifyAt=horizon;config.downscaleFactor=1;config.numDownscales=0;config.keepCrs=true;
        trainer=msplat_trainer_create(dataset,config);require(trainer,"Trainer creation failed");
        int loaded=msplat_trainer_load_checkpoint(trainer,checkpoint.c_str());require(loaded==expectedStep,"Loaded step differs");
        int population=msplat_trainer_splat_count(trainer);require(population==[state[@"splats"] intValue],"Loaded model population changed");
        NSMutableArray* metrics=[NSMutableArray array];double start=now();
        for(auto& target:targets){@autoreleasepool{[metrics addObject:evaluate(trainer,target,output)];}}
        require(msplat_trainer_splat_count(trainer)==population,"Render modified population");
        json(output/"evaluation.json",@{@"status":@"completed",@"checkpointStep":@(loaded),@"splats":@(population),@"metrics":metrics,
            @"trainingStepsExecuted":@0,@"evaluationSeconds":@(now()-start),@"downscaleFactor":@1,@"numDownscales":@0,@"heldOut":@NO,@"memory":memory()});
        msplat_trainer_destroy(trainer);msplat_dataset_destroy(dataset);msplat_cleanup();return 0;
    }catch(const std::exception&error){std::cerr<<error.what()<<std::endl;if(!output.empty())json(output/"native-failure.json",@{@"error":ns(error.what()),@"memory":memory()});
        if(trainer)msplat_trainer_destroy(trainer);if(dataset)msplat_dataset_destroy(dataset);msplat_cleanup();return 1;}
}}
'''
    result = prefix + body
    require('msplat_trainer_step(' not in result and 'msplat_trainer_save_checkpoint(' not in result, 'Evaluation must not contain training or checkpoint writes.')
    return result


def compile_evaluator(source, archive, output, log):
    command = ['xcrun', 'clang++', '-O2', '-std=c++17', '-arch', 'arm64', '-mmacosx-version-min=15.0',
               '-I', str(REPO / 'Vendor/Msplat/core/include'), str(source), str(archive),
               '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'MetalKit',
               '-framework', 'MetalPerformanceShaders', '-framework', 'ImageIO', '-framework', 'CoreGraphics', '-lz', '-o', str(output)]
    with Path(log).open('w') as stream:
        subprocess.run(command, check=True, stdout=stream, stderr=subprocess.STDOUT)
    return command


def validate_snapshot():
    require(digest(SNAPSHOT / 'snapshot.json') == SNAPSHOT_SHA, 'Frozen runtime snapshot metadata changed.')
    snapshot = read_json(SNAPSHOT / 'snapshot.json')
    require(snapshot['jobID'] == EXPECTED_JOB and snapshot['runID'] == EXPECTED_RUN and snapshot['runtimeABI'] == 2,
            'Frozen runtime belongs to another run or ABI.')
    require(snapshot['staticallyLinkedNativeArchiveSHA256'] == ORIGINAL_ARCHIVE_SHA,
            'Frozen evaluator linkage differs from the documented original archive.')
    for name, sha in snapshot['sha256'].items():
        require(Path(name).name == name and digest(SNAPSHOT / name) == sha, 'Frozen artifact changed: ' + name)
    manifest = read_json(SNAPSHOT / 'worker-artifacts.json')
    require(manifest['nativeArchiveSHA256'] == ORIGINAL_ARCHIVE_SHA and manifest['runtimeABI'] == 2,
            'Original helper manifest does not identify the frozen evaluator archive.')
    require(digest(SNAPSHOT / 'msplat-macos.metallib') == manifest['sha256']['msplat-macos.metallib'],
            'Frozen shader differs from the original runtime manifest.')
    require((SNAPSHOT / 'evaluate-checkpoint.mm').read_text() == evaluator_source(),
            'Frozen compiled evaluator source differs from this validated measurement method.')
    return snapshot, manifest


def compare(metrics):
    old = read_json(BASELINE / 'comparison.json')['rows']
    terminal = read_json(TERMINAL / 'comparison-terminal-vs30k.json')['rows']
    result = []
    for current in metrics:
        row = dict(current=current, comparisons={})
        for label, rows, step in [('baseline3000', old, 3000), ('terminal5000', terminal, 5000), ('continuedHorizon30000At5000', old, 5000)]:
            previous = next(value for value in rows if value['frameID'] == current['frameID'] and value['step'] == step)
            require((previous['width'], previous['height']) == (current['width'], current['height']), 'Comparison raster changed.')
            row['comparisons'][label] = dict(reference=previous, delta={key: current[key] - previous[key] for key in ('L1', 'RMSE', 'PSNRdB', 'SSIM')})
        result.append(row)
    return result


def evaluate_run(run, output):
    config, status, dataset, frames = plan(run)
    # Fail before output creation, compilation, model loading or any Metal call.
    require(status['phase'] == 'completed' and status['iteration'] == config['targetIterations'], 'Run is not complete; no evaluation or GPU work started.')
    require(not active_workers(), 'A FormaGaussianWorker is still alive; do not contend with it. Retry after it exits.')
    with (run / 'worker.lock').open('rb') as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('The run worker still owns its lock; no evaluation started.')
        require(not output.exists(), 'Output must be a new isolated directory; existing evidence is never overwritten.')
        result_path = Path(status['resultPath']).resolve()
        require(result_path.is_relative_to(run / 'exports'), 'Completed result path leaves this run.')
        checkpoint, ply = result_path / 'entrenamiento.ckpt', result_path / 'gaussianas.ply'
        metadata = read_json(result_path / 'gaussianas.json')
        require(metadata['jobID'] == config['jobID'] and metadata['steps'] == status['iteration'] and metadata['downscaleFactor'] == 1,
                'Export metadata and completed run differ.')
        require(metadata['numDownscales'] == 0 and metadata['keepCrs'] and metadata['sphericalHarmonicsDegree'] == 3, 'Export policy changed.')
        snapshot, manifest = validate_snapshot()
        require(status.get('runtimeABI') == metadata.get('runtimeABI') == snapshot['runtimeABI'] == 2,
                'Completed checkpoint/export run ABI differs from the frozen evaluator runtime.')
        paths = dataset_inputs(dataset, frames)
        before = {name: digest(path) for name, path in paths.items()}
        original_before = read_json(BASELINE / 'input-sha256-before.json')
        expected = {str(Path(path).resolve().relative_to(dataset)): sha for path, sha in original_before.items() if Path(path).resolve().is_relative_to(dataset)}
        require(before == expected and len(before) == 570, 'Dataset differs from the baseline; do not present an unmatched comparison.')
        checkpoint_sha, ply_sha = digest(checkpoint), digest(ply)
        worker_log = (run / 'worker.log').read_text()
        first_running = None
        reset_steps, densifications = [], []
        for line in worker_log.splitlines():
            if line.startswith('FORMA_GAUSSIAN '):
                event = json.loads(line[len('FORMA_GAUSSIAN '):])
                if first_running is None and event.get('event') == 'running':
                    first_running = event
            elif line.startswith('Opacity reset at step '):
                reset_steps.append(int(line.split()[-1]))
            elif line.startswith('Densified: '):
                parts = line.split()
                densifications.append(dict(before=int(parts[1]), after=int(parts[3])))
        log_evidence = dict(firstRunningEvent=first_running, opacityResetSteps=reset_steps, densifications=densifications,
            freshInitializationConfirmed=bool(first_running and first_running.get('iteration') == 0 and not config.get('resumePath')))
        output.mkdir(parents=True, exist_ok=False)
        write_json(output / 'input-sha256-before.json', dict(dataset=before, checkpoint=checkpoint_sha, ply=ply_sha))
        write_json(output / 'run-config.json', config); write_json(output / 'run-status.json', status); write_json(output / 'export-metadata.json', metadata)
        write_json(output / 'worker-artifacts.json', manifest)
        (output / 'source-worker.log').write_text(worker_log)
        write_json(output / 'training-log-summary.json', log_evidence)
        owned = output / 'evaluation-checkpoint.ckpt'; shutil.copy2(checkpoint, owned)
        require(digest(owned) == checkpoint_sha, 'Owned checkpoint copy differs.')
        metal = output / 'msplat-macos.metallib'; shutil.copy2(SNAPSHOT / 'msplat-macos.metallib', metal)
        source = output / 'evaluate-checkpoint.mm'; shutil.copy2(SNAPSHOT / 'evaluate-checkpoint.mm', source)
        executable = output / 'evaluate-checkpoint'; shutil.copy2(SNAPSHOT / 'evaluate-checkpoint', executable)
        write_json(output / 'runtime-snapshot.json', snapshot)
        build_command = read_json(SNAPSHOT / 'compile-command.json')
        native_command = [str(executable), str(dataset), str(owned), str(metal), str(output), str(config['targetIterations']), str(status['iteration'])]
        with (output / 'native.log').open('w') as log:
            subprocess.run(native_command, check=True, stdout=log, stderr=subprocess.STDOUT)
        state = read_json(output / 'checkpoint-validation.json')
        ply_state = finite_ply(ply, state['splats']); write_json(output / 'ply-validation.json', ply_state)
        require(digest(owned) == checkpoint_sha, 'Evaluation modified its owned checkpoint.')
        after = {name: digest(path) for name, path in paths.items()}
        require(after == before and digest(checkpoint) == checkpoint_sha and digest(ply) == ply_sha, 'An original input changed during evaluation.')
        write_json(output / 'input-sha256-after.json', dict(dataset=after, checkpoint=checkpoint_sha, ply=ply_sha))
        native = read_json(output / 'evaluation.json')
        fingerprints = {str(path.relative_to(REPO)) if path.is_relative_to(REPO) else str(path): digest(path)
                        for path in (Path(__file__).resolve(), REPO / 'Tools/benchmark_gaussian_continuation.mm', source, executable, metal, SNAPSHOT / 'snapshot.json')}
        report = dict(status='completed', jobID=config['jobID'], runID=run.name, trainingStepsExecutedByEvaluator=0,
            fullResolution=True, datasetInputCount=570, datasetHashesMatchBaseline=True, inputHashesUnchanged=True,
            allCheckpointTensorsFinite=state['all18TensorsFinite'], allAdamSecondMomentsNonnegative=state['allAdamSecondMomentsNonnegative'],
            allExportedSH3FloatsFinite=ply_state['allExportedFloatsFinite'], sourceCheckpointSHA256=checkpoint_sha,
            sourcePLY_SHA256=ply_sha, splats=state['splats'], rows=compare(native['metrics']), native=native,
            policy=dict(iterations=30000, stopDensifyAt=30000, downscaleFactor=1, numDownscales=0, keepCrs=True, freshInitializationConfirmed=log_evidence['freshInitializationConfirmed']),
            trainingLog=log_evidence,
            interpretation='Same three training views, not held out. Fresh 30000-step initialization/schedule differs from baseline3000 and resumed terminal5000; no attribution to iterations alone or Polycam superiority.',
            originalBuildCommand=build_command, nativeCommand=native_command, fingerprints=fingerprints,
            runtimeProvenance=dict(snapshotSHA256=SNAPSHOT_SHA, currentVendorOrArchiveUsed=False,
                staticallyLinkedNativeArchiveSHA256=ORIGINAL_ARCHIVE_SHA, originalArchiveRetained=False,
                limitation='The original static archive was replaced by the atomic-lease rebuild. The pinned prebuilt evaluator retains its original linked implementation; exact relinking from that archive is unavailable.'))
        write_json(output / 'comparison.json', report)
        print('Completed read-only evaluation:', output / 'comparison.json')


def self_test():
    import struct
    with tempfile.TemporaryDirectory(prefix='forma-evaluation-cpu-') as directory:
        file = Path(directory) / 'authored.ply'
        names = ['x', 'y', 'z', 'nx', 'ny', 'nz'] + ['f_dc_' + str(i) for i in range(3)] + ['f_rest_' + str(i) for i in range(45)]
        names += ['opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3']
        header = ('ply\nformat binary_little_endian 1.0\nelement vertex 1\n' + ''.join('property float ' + name + '\n' for name in names) + 'end_header\n').encode()
        values = [0.0] * len(names)
        file.write_bytes(header + struct.pack('<' + 'f' * len(names), *values))
        require(finite_ply(file, 1)['checkedFloatCount'] == 62, 'Authored SH3 fixture count differs.')
        for invalid in [header + struct.pack('<' + 'f' * len(names), math.nan, *values[1:]), header + b'\0' * 4]:
            file.write_bytes(invalid)
            try:
                finite_ply(file, 1)
            except ValueError:
                pass
            else:
                raise AssertionError('Invalid PLY was not rejected.')
        require('msplat_trainer_step(' not in evaluator_source(), 'Generated evaluator must not train.')
        validate_snapshot()
    print('PASS: CPU-only SH3 validation, nonfinite/truncation rejection, zero-training source and exact frozen runtime hashes; no Metal calls.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, default=DEFAULT_RUN)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--inspect', action='store_true', help='Read launch policy/IDs only; never allocate a model, compile, or render.')
    parser.add_argument('--self-test', action='store_true', help='Authored CPU-only parser and generated-source checks; no Metal calls.')
    arguments = parser.parse_args()
    try:
        if arguments.self_test:
            self_test(); return
        run = arguments.run.resolve()
        if arguments.inspect:
            config, status, dataset, frames = plan(run)
            print(json.dumps(dict(jobID=config['jobID'], runID=run.name, phase=status['phase'], workerPID=status.get('pid'),
                dataset=str(dataset), datasetIndexSHA256=config['datasetIndexSHA256'], frameCount=len(frames),
                iterations=config['targetIterations'], stopDensifyAt=config['targetIterations'], downscaleFactor=config['downscale'],
                numDownscales=0, keepCrs=True, resumePath=config.get('resumePath'), views=VIEWS, GPUCallsExecuted=0), indent=2)); return
        require(arguments.output is not None, 'Provide a new --output directory, or use --inspect.')
        evaluate_run(run, arguments.output.resolve())
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        parser.exit(2, 'Evaluation not completed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
