#!/usr/bin/env python3
"""Plan/prepare a frozen fresh-gray versus photographic-RGB experiment. Never auto-queues work."""
from pathlib import Path
import argparse
import array
import ctypes
import errno
import fcntl
import hashlib
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid

REPO = Path(__file__).resolve().parent.parent
SCAN = Path.home() / 'Library/Application Support/FormaDesktop/Incoming/8CA53ED6-74E0-4AAB-9B13-6E562562081F'
SEED = REPO / 'build/Research/GaussianColorSeed/room-native-rgb-v1'
PREFIX_SHA = '372cf1ab1bbcd604363d0ff5fcd926e2e446aac05815d0890a9f7c96195ec68f'
VIEWS = [(0, 'C5E81472-7310-4B0E-A41A-3BF478679B1D'),
         (283, 'D57CBC28-36E2-41BA-AD2C-99B1AA8950B5'),
         (565, 'AF41061B-731E-419F-AB9E-36FF365E3A4C')]
NATIVE_PROCESS_NAMES = {'FormaGaussianWorker', 'gaussian-color-seed-arm', 'evaluate-checkpoint',
                        'benchmark-gaussian-continuation', 'benchmark-gaussian-terminal'}


def require(condition, text):
    if not condition:
        raise ValueError(text)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def read_json(path):
    return json.loads(Path(path).read_text())


def parse_workers(text, exclude=()):
    result = []
    for line in text.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and int(fields[0]) not in exclude:
            if Path(fields[1]).name in NATIVE_PROCESS_NAMES:
                result.append(dict(pid=int(fields[0]), executable=fields[1]))
    return result


def workers():
    return parse_workers(subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True))


def require_idle(observed=None):
    active = workers() if observed is None else observed
    require(not active, 'BLOCKED: active Gaussian worker/evaluator exists: ' + json.dumps(active) +
            '. Nothing was signaled, queued, paused, resumed or launched.')


def files_under(root):
    result = []
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'Source symlink is not accepted in this isolated experiment: ' + str(path))
        if path.is_file(): result.append(path)
        else: require(path.is_dir(), 'Unexpected source file type: ' + str(path))
    return result


def clone_copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    require(not destination.exists(), 'Refusing to overwrite a snapshot file')
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    lib.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    lib.clonefile.restype = ctypes.c_int
    if lib.clonefile(os.fsencode(source), os.fsencode(destination), 0) != 0:
        error = ctypes.get_errno()
        require(error in {errno.EXDEV, errno.ENOTSUP, errno.ENOSYS, errno.EINVAL}, 'APFS clone failed: ' + os.strerror(error))
        shutil.copy2(source, destination)
    require(source.stat().st_ino != destination.stat().st_ino or source.stat().st_dev != destination.stat().st_dev,
            'Dataset copy must not be a hardlink')


def point_rows(path):
    return [line.split() for line in path.read_text().splitlines() if line.strip() and not line.lstrip().startswith('#')]


def check_points(original, colored):
    gray, rgb = point_rows(original), point_rows(colored)
    require(len(gray) == len(rgb) == 199868, 'Expected all original room seed points; no truncation is performed')
    require(all(a[:4] == b[:4] and a[7:] == b[7:] for a, b in zip(gray, rgb)), 'A non-RGB point field differs')
    require(all(a[4:7] == ['128', '128', '128'] for a in gray), 'Baseline is not the neutral-gray source')
    require(all(len(row) >= 8 and all(0 <= int(x) <= 255 for x in row[4:7]) for row in rgb), 'Invalid RGB8 seed')
    return len(gray)


def audit_rng(source_root):
    model = (source_root / 'Vendor/Msplat/core/src/model.cpp').read_text()
    api = (source_root / 'Vendor/Msplat/core/src/msplat_api.mm').read_text()
    loader = (source_root / 'Vendor/Msplat/core/src/loaders/load_colmap.cpp').read_text()
    require('std::mt19937 rng(42);' in model and 'std::mt19937 rng(step);' in model, 'Review changed model RNG policy')
    require('std::mt19937 rng{42};' in api and 'std::shuffle(camIndices.begin(), camIndices.end(), rng);' in api,
            'Review changed native camera RNG policy')
    require('std::iota(impl->camIndices.begin(), impl->camIndices.end(), 0);' in api and
            'if (camIterPos >= camIndices.size()) shuffleCameras();' in api, 'Review changed camera cycling policy')
    require('a.filename < b.filename' in loader, 'Review changed native camera ordering')
    return dict(initialQuaternionsSeed=42, cameraShuffleSeed=42, splitSamplesSeed='current step',
                cameraOrdering='filename lexical order, not chronological index',
                reshuffle='same vector shuffled and cycled at each exhausted pass',
                verification='source inspection pinned to runtime manifest; no engine was executed during preparation',
                limitation='Expected schedule is reproduced in the future harness, not an instrumented observation of Trainer internals; Metal floating reductions are not promised bit deterministic')


def native_source():
    helper = REPO / 'Tools/benchmark_gaussian_continuation.mm'
    require(digest(helper) == PREFIX_SHA, 'Validated measurement/checkpoint helper changed; review before preparing')
    prefix = helper.read_text().split('int main(int argc,char**argv)', 1)[0]
    return prefix + r'''
#include <numeric>
#include <random>
#include <sstream>
#include <cstdio>
#include <unistd.h>
static void requireNoForeignWorker() {
    FILE* pipe=popen("/bin/ps -axo pid=,comm=","r");require(pipe,"Cannot inspect process ownership");
    char line[16384];bool busy=false;std::string evidence;
    while(fgets(line,sizeof(line),pipe)) { std::istringstream in(line);int pid;std::string path;in>>pid;std::getline(in,path);auto start=path.find_first_not_of(" \t");if(start==std::string::npos)continue;path=path.substr(start);
        auto name=fs::path(path).filename().string();if(pid!=getpid()&&(name=="FormaGaussianWorker"||name=="gaussian-color-seed-arm"||name=="evaluate-checkpoint"||name=="benchmark-gaussian-continuation"||name=="benchmark-gaussian-terminal")){busy=true;evidence+=std::to_string(pid)+" "+path+"; ";}}
    pclose(pipe);require(!busy,"Foreign native worker became active; owned experiment stops without controlling it: "+evidence);
}
int main(int argc,char**argv) {@autoreleasepool {
    MsplatDataset dataset=nullptr;MsplatTrainer trainer=nullptr;fs::path output;bool initialized=false;
    try {
        require(argc==6,"Usage: OWNED_DATASET MATCHING_METALLIB NEW_OUTPUT STOP_AFTER STAGES_CSV");
        requireNoForeignWorker();fs::path source=fs::canonical(argv[1]),metal=fs::canonical(argv[2]);output=fs::absolute(argv[3]);
        require(!fs::exists(output),"Arm output must be new; this experiment never resumes checkpoints");fs::create_directories(output);
        int stop=std::stoi(argv[4]);require(stop>0&&stop<=30000,"Experimental endpoint must fit the fixed30000 horizon");
        std::vector<int> stages;std::stringstream values(argv[5]);std::string word;while(std::getline(values,word,','))stages.push_back(std::stoi(word));
        require(!stages.empty()&&stages.front()==0&&stages.back()==stop,"Need initial and endpoint stages");
        for(size_t i=1;i<stages.size();i++)require(stages[i]>stages[i-1]&&stages[i]<=stop,"Invalid stages");
        signal(SIGINT,onSignal);signal(SIGTERM,onSignal);
        InputData input=inputDataFromX(source.string());require(input.cameras.size()==566&&input.points.count==199868,"Room input changed");
        NSData* bytes=[NSData dataWithContentsOfFile:ns((source/"dataset.json").string())];NSDictionary* manifest=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
        NSArray* frames=[manifest[@"frames"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){return[a[@"timestamp"] compare:b[@"timestamp"]];}];
        require(frames.count==566,"All 566 observations required");std::vector<Target> targets;
        const std::vector<std::pair<int,std::string>> wanted={{0,"C5E81472-7310-4B0E-A41A-3BF478679B1D"},{283,"D57CBC28-36E2-41BA-AD2C-99B1AA8950B5"},{565,"AF41061B-731E-419F-AB9E-36FF365E3A4C"}};
        for(auto& value:wanted){NSDictionary*frame=frames[value.first];require(value.second==std::string([frame[@"id"] UTF8String]),"Evaluation frame identity changed");fs::path rgb=source/std::string([frame[@"rgbFile"] UTF8String]);int camera=-1;
            for(size_t i=0;i<input.cameras.size();i++)if(fs::path(input.cameras[i].filePath).filename()==rgb.filename()){camera=int(i);break;}
            require(camera>=0,"Missing native evaluation camera");targets.push_back({camera,value.first,value.second,rgb});}
        std::vector<size_t> order(566);std::iota(order.begin(),order.end(),0);std::mt19937 rng(42);std::shuffle(order.begin(),order.end(),rng);size_t next=0;
        std::ofstream schedule(output/"expected-camera-schedule.csv");schedule<<"step,nativeCameraIndex,filename\n";
        for(int step=1;step<=stop;step++){if(next==order.size()){std::shuffle(order.begin(),order.end(),rng);next=0;}auto camera=order[next++];schedule<<step<<','<<camera<<','<<fs::path(input.cameras[camera].filePath).filename().string()<<'\n';}schedule.close();
        json(output/"configuration.json",@{@"horizon":@30000,@"stopDensifyAt":@30000,@"numDownscales":@0,@"downscaleFactor":@1,@"keepCrs":@YES,@"shDegree":@3,@"shDegreeInterval":@1000,@"ssimWeight":@0.2,
            @"refineEvery":@100,@"warmupLength":@500,@"resetAlphaEvery":@30,@"resolutionSchedule":@3000,@"stopScreenSizeAt":@4000,@"splitScreenSize":@0.05,@"densifyGradThresh":@0.0002,@"densifySizeThresh":@0.01,
            @"bgColor":@[@0.613,@0.0101,@0.3984],@"stopAfter":@(stop),@"freshInitialization":@YES,@"resumeCheckpointLoaded":@NO,@"trainingCameraCount":@566,@"heldOut":@NO,@"initialSeedPoints":@199868,@"cameraAndQuaternionSeed":@42});
        requireNoForeignWorker();initialized=true;msplat_set_metallib_path(metal.c_str());dataset=msplat_dataset_create(source.c_str(),1,false,8);require(dataset&&msplat_dataset_num_train(dataset)==566&&msplat_dataset_num_test(dataset)==0,"Dataset split differs");
        auto config=msplat_default_config();config.iterations=30000;config.stopDensifyAt=30000;config.keepCrs=true;config.downscaleFactor=1;config.numDownscales=0;
        trainer=msplat_trainer_create(dataset,config);require(trainer,"Fresh trainer creation failed");require(msplat_trainer_iteration(trainer)==0,"Fresh experiment cannot resume");
        double start=now();int step=0;NSMutableArray* summaries=[NSMutableArray array];
        for(int target:stages) {@autoreleasepool {
            while(step<target&&!interrupted) {@autoreleasepool {requireNoForeignWorker();auto stats=msplat_trainer_step(trainer);msplat_sync();step=stats.iteration;require(step<=target,"Step overshot exact endpoint");
                if(step%25==0)json(output/"progress.json",@{@"step":@(step),@"splats":@(stats.splatCount),@"horizon":@30000,@"stopAfter":@(stop),@"memory":memory(),@"elapsedSeconds":@(now()-start)});}}
            if(interrupted)break;requireNoForeignWorker();fs::path directory=output/std::to_string(target);fs::create_directory(directory);
            msplat_trainer_save_checkpoint(trainer,(directory/"entrenamiento.ckpt").c_str());auto state=checkCheckpoint(directory/"entrenamiento.ckpt");require([state[@"step"] intValue]==target,"Checkpoint step differs");json(directory/"checkpoint-validation.json",state);
            msplat_trainer_export_ply(trainer,(directory/"gaussianas.ply").c_str());NSMutableArray* metrics=[NSMutableArray array];
            for(auto& view:targets){@autoreleasepool{requireNoForeignWorker();[metrics addObject:evaluate(trainer,view,directory)];}}
            NSDictionary* summary=@{@"step":@(target),@"metrics":metrics,@"splats":@(msplat_trainer_splat_count(trainer)),@"memory":memory(),@"elapsedSeconds":@(now()-start),@"all18TensorsFinite":@YES,@"allAdamVNonnegative":@YES};
            json(directory/"summary.json",summary);[summaries addObject:summary];
        }}
        if(interrupted){msplat_trainer_save_checkpoint(trainer,(output/"interrupted.ckpt").c_str());json(output/"interrupted-validation.json",checkCheckpoint(output/"interrupted.ckpt"));}
        json(output/"summary.json",@{@"status":interrupted?@"interrupted-owned-checkpoint-preserved":@"completed",@"stages":summaries,@"heldOut":@NO,@"horizon":@30000,@"stopAfter":@(stop),@"trainingStepsExecuted":@(step),@"memory":memory()});
        msplat_trainer_destroy(trainer);trainer=nullptr;msplat_dataset_destroy(dataset);dataset=nullptr;msplat_cleanup();return interrupted?2:0;
    }catch(const std::exception& e){if(!output.empty()&&fs::exists(output))json(output/"failure.json",@{@"error":ns(e.what()),@"memory":memory()});std::cerr<<e.what()<<std::endl;
        if(trainer)msplat_trainer_destroy(trainer);if(dataset)msplat_dataset_destroy(dataset);if(initialized)msplat_cleanup();return 1;}
}}
'''


def prepare(args):
    import verify_gaussian_worker as artifacts
    output, source, seed = args.output.resolve(), args.dataset.resolve(), args.seed.resolve()
    require(not output.exists(), 'Output must be new; existing experiments never get overwritten')
    require(not output.is_relative_to(source) and not source.is_relative_to(output), 'Output must be independent of source capture')
    runtime = artifacts.verify_artifacts(REPO, args.runtime.resolve())  # Artifact hashes only; never acceptance()/worker execution.
    rng = audit_rng(REPO)
    frames = sorted(read_json(source/'dataset.json')['frames'], key=lambda f:f['timestamp'])
    require(len(frames) == 566 and all(frames[i]['id'] == uid for i,uid in VIEWS), 'This declared experiment uses the exact566-frame room')
    seed_manifest = read_json(seed/'seed-manifest.json')
    require(digest(source/'points3D.txt') == seed_manifest['sourcePointsSHA256'] and
            digest(seed/'points3D.txt') == seed_manifest['seedPointsSHA256'], 'Seed is not derived from these exact original points')
    count = check_points(source/'points3D.txt', seed/'points3D.txt')
    files = files_under(source)
    sources = {str(p):digest(p) for p in files}
    sources[str(seed/'points3D.txt')] = digest(seed/'points3D.txt')
    sources[str(seed/'seed-manifest.json')] = digest(seed/'seed-manifest.json')
    output.mkdir(parents=True)
    write_json(output/'input-sha256-before.json', sources)
    stages = sorted({0,min(1000,args.steps),args.steps})
    plan = dict(schemaVersion=1, status='dry-run' if args.dry_run else 'prepared-not-executed', experimentID=str(uuid.uuid4()),
                treatment='Only initial points3D RGB8 columns change; no geometry/pose/K/count or product default change',
                sourceDataset=str(source), seedDirectory=str(seed), sourceFileCount=len(sources), sourcesSHA256=sources,
                horizon=30000, stopDensifyAt=30000, stopAfter=args.steps, evaluationSteps=stages,
                downscale=1, numDownscales=0, keepCrs=True, initialPointCount=count, trainingCameraCount=len(frames),
                freshInitialization=True, resumePath=None, rng=rng, arms=['gray','rgb'],
                views=[dict(chronologicalIndex=i,frameID=uid,filename=frames[i]['rgbFile']) for i,uid in VIEWS],
                heldOut=False, heldOutReason='All566photos train and the complete RGBseed was selected from those photos. Native evalMode true alone would not remove initialization leakage. A separate paired experiment needs a new seed using only training observations.',
                activeWorkersObservedDuringCPUPreparation=workers(), noGPUExecutedDuringPreparation=True,
                nativeRuntime=runtime, runtimeDirectory=str(output/'runtime'),
                limitations=['Single paired pilot; arm order/warm caches and GPU numerical reductions prevent a claim of statistical significance or bit-identical training.',
                             'All evaluations use observed training views, not reserved views or a Polycam comparison.',
                             'Research stopAfter is an exact configurable observation endpoint; LR/refinement horizon stays30000 and no product quota is introduced.',
                             'Process guards observe workers without controlling them; they are not a system-wide atomic GPU reservation. Keep other training launches stopped during a future experiment.'],
                creatorSHA256=digest(Path(__file__)))
    if not args.dry_run:
        snapshot=output/'runtime';snapshot.mkdir()
        for relative in runtime['sourceSHA256']:
            destination=snapshot/'source'/relative;clone_copy(REPO/relative,destination)
            require(digest(destination)==runtime['sourceSHA256'][relative], 'Runtime source snapshot mismatch')
        for name in ['FormaGaussianWorker','msplat-macos.metallib','worker-artifacts.json']:
            clone_copy(args.runtime.resolve()/name,snapshot/name)
        clone_copy(args.runtime.resolve()/'native/libmsplat_core.a',snapshot/'libmsplat_core.a')
        helper=snapshot/'gaussian-color-seed-arm.mm';helper.write_text(native_source())
        executable=snapshot/'gaussian-color-seed-arm'
        command=['xcrun','clang++','-O2','-std=c++17','-arch','arm64','-mmacosx-version-min=15.0','-I',str(snapshot/'source/Vendor/Msplat/core/include'),str(helper),str(snapshot/'libmsplat_core.a'),
                 '-framework','Foundation','-framework','Metal','-framework','MetalKit','-framework','MetalPerformanceShaders','-framework','ImageIO','-framework','CoreGraphics','-lz','-o',str(executable)]
        with (snapshot/'compile.log').open('w') as log: subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT)
        write_json(snapshot/'compile-command.json',command)
        plan['runtimeSnapshotSHA256']={str(p.relative_to(snapshot)):digest(p) for p in files_under(snapshot)}
        require(digest(snapshot/'libmsplat_core.a')==runtime['nativeArchiveSHA256'], 'Frozen archive differs')
        expected={str(p.relative_to(source)):sources[str(p)] for p in files}
        for arm in plan['arms']:
            target=output/'datasets'/arm
            for p in files:clone_copy(p,target/p.relative_to(source))
            if arm=='rgb':shutil.copyfile(seed/'points3D.txt',target/'points3D.txt')
            actual={str(p.relative_to(target)):digest(p) for p in files_under(target)}
            wanted=dict(expected)
            if arm=='rgb':wanted['points3D.txt']=seed_manifest['seedPointsSHA256']
            require(actual==wanted, 'Dataset copy changed a non-treatment file')
            plan.setdefault('datasetCopiesSHA256',{})[arm]=actual
    after={path:digest(path) for path in sources};require(after==sources,'Source changed during CPU preparation')
    write_json(output/'input-sha256-after.json',after)
    write_json(output/'plan.json',plan)
    (output/Path(__file__).name).write_bytes(Path(__file__).read_bytes())
    print(json.dumps(dict(status=plan['status'],plan=str(output/'plan.json'),activeWorkers=plan['activeWorkersObservedDuringCPUPreparation'],nativeProcessesExecuted=0),indent=2))


def verify_prepared(output):
    plan=read_json(output/'plan.json');require(plan['status']=='prepared-not-executed','Dry-run has no datasets/runtime')
    require(plan['horizon']==plan['stopDensifyAt']==30000 and plan['downscale']==1 and plan['resumePath'] is None,'Plan policy changed')
    require(plan['creatorSHA256']==digest(output/Path(__file__).name),'Creator snapshot changed')
    require(plan['creatorSHA256']==digest(Path(__file__)),'Invoke the frozen copied script; current script differs from this plan')
    snapshot=output/'runtime'
    require({str(p.relative_to(snapshot)):digest(p) for p in files_under(snapshot)}==plan['runtimeSnapshotSHA256'],'Frozen runtime changed')
    for arm,expected in plan['datasetCopiesSHA256'].items():
        folder=output/'datasets'/arm;require({str(p.relative_to(folder)):digest(p) for p in files_under(folder)}==expected,'Owned dataset changed')
    require({p:digest(p) for p in plan['sourcesSHA256']}==plan['sourcesSHA256'],'Original source/seed changed')
    return plan


def checkpoint_tensors(path):
    with path.open('rb') as f:
        header=f.read(24);values=struct.unpack('<6I',header)
        require(values[0]==1280332621 and values[1]==1,'Unexpected checkpoint format')
        rates=f.read(32);require(all(math.isfinite(x) for x in struct.unpack('<8f',rates)),'Nonfinite LR')
        tensors=[]
        for index in range(18):
            rank=struct.unpack('<I',f.read(4))[0];require(1<=rank<=4,'Invalid tensor rank')
            shape=list(struct.unpack('<'+'q'*rank,f.read(rank*8)));require(all(x>0 for x in shape),'Invalid tensor shape')
            length=struct.unpack('<Q',f.read(8))[0];require(length==math.prod(shape)*4,'Invalid tensor length')
            h=hashlib.sha256();remaining=length
            while remaining:
                block=f.read(min(1024*1024,remaining));require(block and len(block)%4==0,'Truncated tensor')
                h.update(block);remaining-=len(block);floats=array.array('f');floats.frombytes(block)
                if sys.byteorder!='little':floats.byteswap()
                require(all(math.isfinite(x) for x in floats),'Nonfinite model/optimizer tensor')
                if index>=12:require(all(x>=0 for x in floats),'Negative Adam second moment')
            tensors.append(dict(index=index,shape=shape,sha256=h.hexdigest()))
        require(not f.read(1),'Unexpected checkpoint tail')
    return dict(header=header.hex(),rates=rates.hex(),step=values[2],splats=values[3],tensors=tensors)


def compare_initial(gray,rgb):
    a,b=checkpoint_tensors(gray),checkpoint_tensors(rgb)
    require(a['step']==b['step']==0 and a['header']==b['header'] and a['rates']==b['rates'],'Initial header/LR differs')
    for index,(x,y) in enumerate(zip(a['tensors'],b['tensors'])):
        require(x['shape']==y['shape'],'Initial tensor dimensions differ')
        if index!=3:require(x['sha256']==y['sha256'],'Initial non-DC tensor differs: '+str(index))
    require(a['tensors'][3]['sha256']!=b['tensors'][3]['sha256'],'Treatment did not change initial DC')
    return dict(status='passed',step=0,splats=a['splats'],allInitialTensorsExactlyEqualExceptDC=True,
                DCChanged=True,all18TensorsFinite=True,allAdamVNonnegative=True,gray=a,rgb=b)


def validate_ply(path,expected_count):
    with path.open('rb') as f:
        require(f.readline()==b'ply\n','Missing PLY signature');properties=[];count=None;fmt=None
        while True:
            raw=f.readline();require(raw,'Truncated PLY header');fields=raw.decode('ascii').strip().split()
            if fields[:1]==['format']:fmt=fields[1:]
            elif fields[:2]==['element','vertex']:count=int(fields[2])
            elif fields[:1]==['property']:
                require(len(fields)==3 and fields[1]=='float','Unexpected PLY layout');properties.append(fields[2])
            elif fields==['end_header']:break
        expected=['x','y','z','nx','ny','nz']+['f_dc_'+str(i) for i in range(3)]+['f_rest_'+str(i) for i in range(45)]+['opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3']
        require(fmt==['binary_little_endian','1.0'] and properties==expected and count==expected_count,'PLY lost population or SH3 fields')
        remaining=count*len(properties)*4
        while remaining:
            raw=f.read(min(1024*1024,remaining));require(raw and len(raw)%4==0,'Truncated PLY');remaining-=len(raw)
            values=array.array('f');values.frombytes(raw)
            if sys.byteorder!='little':values.byteswap()
            require(all(math.isfinite(x) for x in values),'Nonfinite PLY')
        require(not f.read(1),'Unexpected PLY tail')
    return dict(splats=count,SHDegree=3,allFloatsFinite=True,sha256=digest(path))


def run(output):
    # Explicit invocation only. Busy means error, never wait/queue/control a real job.
    require_idle()
    plan=verify_prepared(output)
    lock=(output/'experiment.lock').open('a+')
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    require(not (output/'runs').exists(),'Fresh paired experiment already attempted; preserve it and prepare a new output')
    for arm in plan['arms']:
        require_idle()
        target=output/'runs'/arm;target.parent.mkdir(parents=True,exist_ok=True)
        command=[str(output/'runtime/gaussian-color-seed-arm'),str(output/'datasets'/arm),str(output/'runtime/msplat-macos.metallib'),str(target),str(plan['stopAfter']),','.join(map(str,plan['evaluationSteps']))]
        with (output/f'{arm}-native.log').open('w') as log: subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT)
        verify_prepared(output)
    verify_prepared(output)
    a=(output/'runs/gray/expected-camera-schedule.csv').read_bytes();b=(output/'runs/rgb/expected-camera-schedule.csv').read_bytes()
    require(a==b,'Expected camera schedules differ')
    initial=compare_initial(output/'runs/gray/0/entrenamiento.ckpt',output/'runs/rgb/0/entrenamiento.ckpt')
    write_json(output/'initial-parameter-comparison.json',initial)
    deltas=[];exports=[]
    for stage in plan['evaluationSteps']:
        gray=read_json(output/f'runs/gray/{stage}/summary.json');rgb=read_json(output/f'runs/rgb/{stage}/summary.json')
        for arm,summary in [('gray',gray),('rgb',rgb)]:
            exports.append(dict(arm=arm,step=stage,validation=validate_ply(output/f'runs/{arm}/{stage}/gaussianas.ply',summary['splats'])))
        for x,y in zip(gray['metrics'],rgb['metrics']):
            require(x['frameID']==y['frameID'] and (x['width'],x['height'])==(y['width'],y['height']),'Paired evaluation observations differ')
            delta={name:y[name]-x[name] for name in ['L1','RMSE','PSNRdB','SSIM']}
            require(all(math.isfinite(v) for v in delta.values()),'Nonfinite paired metric')
            deltas.append(dict(step=stage,frameID=x['frameID'],rgbMinusGray=delta,gray=x,rgb=y))
    write_json(output/'paired-run-completed.json',dict(status='completed-requires-quality-review',horizon=30000,stepsPerArm=plan['stopAfter'],heldOut=False,
               expectedCameraScheduleSHA256=hashlib.sha256(a).hexdigest(),sourceSHA256Unchanged=True,arms=plan['arms'],
               initialParametersVerified=True,exports=exports,metrics=deltas,limitation='One paired observed-training-view pilot; no statistical significance or Polycam superiority claim'))


def self_test():
    active=parse_workers('51835 /Applications/FormaDesktop.app/Contents/Helpers/FormaGaussianWorker\n33 /usr/bin/python3\n99 /tmp/gaussian-color-seed-arm\n')
    require([x['pid'] for x in active]==[51835,99],'Worker parser missed native process')
    rejected=False
    try:require_idle(active)
    except ValueError:rejected=True
    require(rejected,'Active engine did not reject before any launch')
    require_idle([])
    with tempfile.TemporaryDirectory(prefix='forma-color-ab-test-') as d:
        a=Path(d)/'source';b=Path(d)/'copy';a.write_bytes(b'preserve source');clone_copy(a,b);b.write_bytes(b'owned mutation')
        require(a.read_bytes()==b'preserve source','Clone/copy mutated original')
        def fixture(path,dc,means=0.):
            with path.open('wb') as f:
                f.write(struct.pack('<6I8f',1280332621,1,0,4,3,0,*([0.]*8)))
                for i in range(18):
                    shape=[4,[3,3,4,3,45,1][i%6]];n=math.prod(shape)
                    f.write(struct.pack('<IqqQ',2,*shape,n*4));value=dc if i==3 else means if i==0 else 0.
                    f.write(struct.pack('<'+'f'*n,*([value]*n)))
        gray,rgb=Path(d)/'gray.ckpt',Path(d)/'rgb.ckpt';fixture(gray,0.);fixture(rgb,.1);compare_initial(gray,rgb)
        fixture(rgb,.1,means=.2);rejected=False
        try:compare_initial(gray,rgb)
        except ValueError:rejected=True
        require(rejected,'Non-color initialization mutation was not rejected')
    require('msplat_trainer_load_checkpoint(' not in native_source(),'Fresh harness unexpectedly resumes')
    print('PASS: CPU process-guard rejection, no autoqueue, independent copy mutation, initial tensor control/rejection, no resume call')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--dataset',type=Path,default=SCAN/'dataset')
    parser.add_argument('--seed',type=Path,default=SEED)
    parser.add_argument('--runtime',type=Path,default=REPO/'build/GaussianDesktopWorker')
    parser.add_argument('--steps',type=int,default=3000,help='Research endpoint only; native horizon remains30000')
    modes=parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--prepare',action='store_true',help='CPU only: freeze runtime, compile without execution, clone datasets')
    modes.add_argument('--dry-run',action='store_true',help='CPU only: store plan and input hashes, no dataset copy or compilation')
    modes.add_argument('--check-ready',action='store_true',help='CPU process check only; active workers produce an immediate error')
    modes.add_argument('--run',action='store_true',help='EXPLICIT future GPU execution; refuses while a worker/evaluator is active')
    modes.add_argument('--self-test',action='store_true',help='CPU-only guards/copy regressions; never creates a native model')
    args=parser.parse_args()
    try:
        require(1<=args.steps<=30000,'Experimental endpoint must fit the declared30000 horizon')
        if args.self_test:self_test()
        elif args.check_ready:require_idle();print('READY: no recognized native Gaussian worker/evaluator; no process was launched')
        else:
            require(args.output is not None,'--output required')
            if args.run:run(args.output.resolve())
            else:prepare(args)
    except (OSError,ValueError,KeyError,AssertionError,subprocess.CalledProcessError) as error:
        parser.exit(2,'error: '+str(error)+'\n')


if __name__=='__main__':
    main()
