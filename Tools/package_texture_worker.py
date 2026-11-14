#!/usr/bin/env python3
"""Package the reviewed CPU texture worker and transitive non-system dylibs.
Only copies installed dependencies; never downloads or modifies Homebrew originals.
The output folder may be copied intact into Contents/Helpers/PhotographicTextureWorker/.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def run(*cmd):return subprocess.check_output([str(x) for x in cmd],text=True,stderr=subprocess.STDOUT)
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1<<20),b''):h.update(block)
    return h.hexdigest()
def unsigned_sha(path):
    with tempfile.TemporaryDirectory(prefix='forma-texture-signature-') as tmp:
        copied=Path(tmp)/path.name;shutil.copy2(path,copied)
        subprocess.run(['/usr/bin/codesign','--remove-signature',str(copied)],check=True,capture_output=True)
        return sha(copied)
def deps(path):return [line.strip().split(' (compatibility version',1)[0] for line in run('/usr/bin/otool','-L',path).splitlines()[1:]]
def system(path):return path.startswith('/usr/lib/') or path.startswith('/System/Library/')
def rpaths(path):return re.findall(r'cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.+?) \(offset',run('/usr/bin/otool','-l',path))
def resolve(dep,parent):
    if dep.startswith('@loader_path/'):return (parent.parent/dep[len('@loader_path/'):]).resolve(strict=True)
    if dep.startswith('@rpath/'):
        for directory in rpaths(parent):
            directory=directory.replace('@loader_path',str(parent.parent))
            candidate=Path(directory)/dep[len('@rpath/'):]
            if candidate.exists():return candidate.resolve()
        raise ValueError('Cannot resolve runtime dependency '+dep+' from '+str(parent))
    return Path(dep).resolve(strict=True)
def sources(source):
    wanted={'.h','.hpp','.cpp','.cc','.c','.cmake','.in','.ipp','.inc'}
    paths=[p for p in source.rglob('*') if p.is_file() and '.git' not in p.parts and (p.suffix.lower() in wanted or p.name=='CMakeLists.txt')]
    paths += [ROOT/'Tools/mvs-texturing-forma.patch',ROOT/'Tools/package_texture_worker.py',ROOT/'Tools/verify_texture_worker.py',ROOT/'scripts/build_texture_worker.sh']
    hashes={str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p):sha(p) for p in sorted(paths)}
    return hashes,hashlib.sha256(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def package(source,executable,output):
    if output.exists():raise ValueError('Output exists; keep prior artifact evidence or choose a new output: '+str(output))
    output.parent.mkdir(parents=True,exist_ok=True)
    stage=Path(tempfile.mkdtemp(prefix='.texture-worker-',dir=output.parent))
    try:
        frameworks=stage/'Libraries';frameworks.mkdir();licenses=stage/'Licenses';licenses.mkdir()
        library_by_source={};queue=[executable];edges={}
        while queue:
            parent=queue.pop();edges[parent]=[]
            for dep in deps(parent):
                if system(dep):continue
                actual=resolve(dep,parent)
                if actual==parent:continue # dylib install ID is not an extra dependency
                if actual not in library_by_source:
                    name=actual.name
                    for prior,filename in library_by_source.items():
                        if filename==name and sha(prior)!=sha(actual):raise ValueError('Conflicting dylib basenames: '+name)
                    library_by_source[actual]=name;queue.append(actual)
                edges[parent].append((dep,actual))
        targets={executable:stage/'texrecon'}
        targets.update({p:frameworks/n for p,n in library_by_source.items()})
        for original,destination in targets.items():
            shutil.copy2(original,destination);os.chmod(destination,0o755)
        for original,destination in targets.items():
            # Remove the copied signature before editing, never touch an original.
            subprocess.run(['/usr/bin/codesign','--remove-signature',str(destination)],capture_output=True)
            if original!=executable:run('/usr/bin/install_name_tool','-id','@loader_path/'+destination.name,destination)
            for dep,target in edges[original]:
                relative=('@loader_path/Libraries/' if original==executable else '@loader_path/')+library_by_source[target]
                run('/usr/bin/install_name_tool','-change',dep,relative,destination)
            for path in rpaths(destination):run('/usr/bin/install_name_tool','-delete_rpath',path,destination)
            run('/usr/bin/codesign','--force','--sign','-',destination)
        notice_sources=[]
        def retain(label,paths):
            copied=[];folder=licenses/label;folder.mkdir(exist_ok=True)
            for p in paths:
                if p.is_file():shutil.copy2(p,folder/p.name);copied.append(str((folder/p.name).relative_to(stage)))
            if not copied:raise ValueError('No local license text for '+label)
            notice_sources.append(dict(component=label,files=copied))
        retain('mvs-texturing',[source/'LICENSE.txt'])
        for component in ['mve','rayint','mapmap']:retain(component,[source/'elibs'/component/'LICENSE.txt'])
        retain('mapmap-dset',[source/'elibs/mapmap/ext/dset/LICENSE.txt'])
        retain('Eigen',list((source/'elibs/eigen').glob('COPYING*')))
        formulae={}
        for original in library_by_source:
            # Real paths are Homebrew Cellar/formula/version/lib/file.
            parts=original.parts
            if 'Cellar' not in parts:raise ValueError('Missing local notice policy for non-Homebrew dependency '+str(original))
            i=parts.index('Cellar');formula=parts[i+1];formula_root=Path(*parts[:i+3]);formulae[formula]=formula_root
        for formula,folder in sorted(formulae.items()):
            texts=[p for p in folder.iterdir() if p.is_file() and re.match(r'(?i)(license|copying|notice|patents)',p.name)]
            if formula=='jpeg-turbo':texts += list(folder.glob('share/doc/libjpeg-turbo/README.ijg'))
            retain(formula,texts)
        (licenses/'FORMA-NOTICES.md').write_text('''# Forma photographic texture worker\n\nModified mvs-texturing (BSD 3-Clause), MVE/rayint/mapMAP (their retained BSD notices), and mapMAP dset (zlib-style notice). Forma modifications add native Apple LUT projection, bounded working-set batching, and geometry-preserving labels-only output; upstream authors do not endorse Forma.\n\nEigen 3.4.0 is used without modifications with EIGEN_MPL2_ONLY; its applicable MPL 2.0 and accompanying notices are retained. Corresponding official source: https://gitlab.com/libeigen/eigen/-/tree/3.4.0 . oneTBB and LLVM OpenMP have their own retained licenses, including applicable LLVM exceptions. Image codec/transitive dependency notices are retained per installed component, not relabeled as BSD.\n\nOfficial project sources: https://github.com/nmoehrle/mvs-texturing ; https://github.com/nmoehrle/mve ; https://github.com/nmoehrle/rayint ; https://github.com/dthuerck/mapmap_cpu .\n\nThis folder is a build artifact for a local macOS worker, not a statement of measured reconstruction superiority. It requires no paid service, ComfyUI, runtime compiler, or Homebrew installation on the runtime machine. System libraries remain provided by macOS.\n''')
        files={str(p.relative_to(stage)):sha(p) for p in sorted(stage.rglob('*')) if p.is_file()}
        source_hashes,fingerprint=sources(source)
        manifest=dict(schemaVersion=1,workerABI='FORMA_LABELS_ONLY_V1',architecture='arm64',workerRelativePath='texrecon',frameworksRelativePath='Libraries',sources=source_hashes,sourceFingerprintSHA256=fingerprint,sourceRoot=str(source),sourceGitCommit=run('git','-C',source,'rev-parse','HEAD').strip(),files=files,unsignedMachOSHA256={str(p.relative_to(stage)):unsigned_sha(p) for p in targets.values()},dependencies=[dict(original=str(p),packaged='Libraries/'+n,sourceSHA256=sha(p)) for p,n in sorted(library_by_source.items())],notices=notice_sources,systemDependenciesOnlyOutsideBundle=True)
        (stage/'worker-artifacts.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
        stage.rename(output)
    finally:
        if stage.exists():shutil.rmtree(stage)
    verify(output)
def verify(output):
    manifest=json.loads((output/'worker-artifacts.json').read_text());assert manifest['workerABI']=='FORMA_LABELS_ONLY_V1'
    for rel,digest in manifest['files'].items():
        path=output/rel
        if rel in manifest['unsignedMachOSHA256']:
            assert unsigned_sha(path)==manifest['unsignedMachOSHA256'][rel], 'Changed Mach-O '+rel
            run('/usr/bin/codesign','--verify','--strict',path)
            assert not rpaths(path),'Unexpected runtime rpath '+rel
            for dep in deps(path):
                if system(dep):continue
                if dep=='@loader_path/'+path.name and rel.startswith('Libraries/'):continue
                assert dep.startswith('@loader_path/'),'Nonlocal dependency '+dep
                assert resolve(dep,path).is_relative_to(output.resolve()),'Escaped bundle dependency '+dep
        else:assert sha(path)==digest,'Changed artifact '+rel
    current={}
    for path,digest in manifest['sources'].items():
        p=Path(path);p=p if p.is_absolute() else ROOT/p
        if not p.exists():raise ValueError('Source unavailable for build verification: '+str(p))
        current[path]=sha(p)
        assert current[path]==digest,'Changed source; rebuild texture worker: '+path
    assert hashlib.sha256(json.dumps(current,sort_keys=True,separators=(',',':')).encode()).hexdigest()==manifest['sourceFingerprintSHA256']
    help_result=subprocess.run([str(output/'texrecon'),'--help'],capture_output=True,text=True)
    help_text=help_result.stdout+help_result.stderr
    assert help_result.returncode in (0,1) and 'forma_labels_only' in help_text and 'forma_native_lut' in help_text
    print(json.dumps(dict(status='passed',bundle=str(output),workerABI=manifest['workerABI'],packagedDylibs=len(manifest['dependencies']),notices=len(manifest['notices']),selfContainedDependencies=True)))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--source',type=Path);p.add_argument('--executable',type=Path);p.add_argument('--verify',action='store_true');a=p.parse_args()
    if a.verify:verify(a.output.resolve())
    else:
        if not a.source or not a.executable:p.error('--source and --executable required for packaging')
        package(a.source.resolve(),a.executable.resolve(),a.output.resolve())
