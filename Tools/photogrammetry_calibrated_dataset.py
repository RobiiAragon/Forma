#!/usr/bin/env python3
"""CPU-only validation of native Apple photogrammetry calibration, then optional COLMAP copy.

Never runs reconstruction, GPU, training, or modifies capture inputs. Export is
refused for ambiguous reprojection, missing cameras/K, or unrepresented distortion.
Thresholds apply only to this diagnostic evidence, never capture/product quotas.
"""
from pathlib import Path
import os
os.environ['OPENCV_OPENCL_RUNTIME'] = 'disabled'
os.environ['OPENBLAS_NUM_THREADS'] = '2'
os.environ['OMP_NUM_THREADS'] = '2'
import argparse, copy, ctypes, hashlib, itertools, json, math, shutil, sys, tempfile, time
import concurrent.futures
from photogrammetry_rectification import lens_model, rectify_frame, forward_xy, APPLE_LUT_SOURCE
import cv2
import numpy as np
cv2.ocl.setUseOpenCL(False)
cv2.setNumThreads(2)
FLIP_GL_CV = np.diag([1., -1., -1., 1.])

def require(ok, message):
    if not ok: raise ValueError(message)

def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for x in iter(lambda:f.read(1048576),b''):h.update(x)
    return h.hexdigest()

def dump(path, value):
    Path(path).write_text(json.dumps(value,indent=2,sort_keys=True,allow_nan=False)+'\n')

def matrix(values,n):
    m=np.asarray(values,dtype=np.float64).reshape((n,n),order='F')
    require(np.isfinite(m).all(),'Nonfinite native camera matrix.')
    return m

def safe_file(root, relative):
    require(isinstance(relative,str) and relative and not relative.startswith('/') and '\\' not in relative and '\0' not in relative,'Unsafe relative capture path.')
    require(all(x not in ('','.','..') for x in relative.split('/')),'Unsafe capture path components.')
    path=root/relative
    require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root.resolve()),'Capture source must be a contained regular file: '+relative)
    return path

def read_points(path):
    with Path(path).open('r',encoding='ascii') as f:
        require(f.readline().strip()=='ply','Expected native ASCII PLY point cloud.')
        require(f.readline().strip()=='format ascii 1.0','Only the CLI ASCII PLY is accepted.')
        properties=[];count=None;vertex=False
        for line in f:
            row=line.split()
            if not row:continue
            if row[0]=='element':
                vertex=row[1]=='vertex'
                if vertex:count=int(row[2])
                elif int(row[2])!=0:raise ValueError('Unexpected non-vertex PLY element.')
            elif row[0]=='property' and vertex:
                require(len(row)==3 and row[1]!='list','Unexpected PLY vertex property.')
                properties.append(row[2])
            elif row[0]=='end_header':break
        require(count is not None and count>0,'Point cloud contains no points.')
        require(set(('x','y','z','red','green','blue')).issubset(properties),'Point cloud lacks native XYZ/RGB.')
        data=np.empty((count,len(properties)),np.float64)
        for i in range(count):
            values=f.readline().split();require(len(values)==len(properties),'Truncated PLY vertex record.')
            data[i]=[float(x) for x in values]
        require(not f.read().strip(),'Unexpected extra PLY payload.')
    require(np.isfinite(data).all(),'Nonfinite native point cloud; nothing was filtered.')
    xyz=data[:,[properties.index(x) for x in ('x','y','z')]]
    rgb=data[:,[properties.index(x) for x in ('red','green','blue')]]
    require(((rgb>=0)&(rgb<=255)&(rgb==np.rint(rgb))).all(),'Native colors are not RGB8.')
    return xyz,rgb.astype(np.uint8)

def hypotheses():
    return [(direction,signs) for direction in ('C2W','W2C') for signs in itertools.product((1,-1),repeat=3)]

def hypothesis_name(direction,signs):return direction+'_'+''.join('+' if x==1 else '-' for x in signs)

def world_to_cv(native,direction,signs):
    w2c=np.linalg.inv(native) if direction=='C2W' else native
    return np.diag([*signs,1.])@w2c

def projected_visible(xyz,k,w2c,width,height,native_lens=None):
    local=np.einsum('ni,ji->nj',xyz,w2c[:3,:3],optimize=False)+w2c[:3,3]
    z=local[:,2]
    projected=np.einsum('ni,ji->nj',local,k,optimize=False)
    uv=np.full((len(xyz),2),np.nan)
    front=z>1e-8
    uv[front]=projected[front,:2]/projected[front,2,None]
    if native_lens is not None:
        mapped_x,mapped_y=forward_xy(uv[front,0],uv[front,1],native_lens)
        uv[front]=np.column_stack([mapped_x,mapped_y])
    inside=front & np.isfinite(uv).all(axis=1) & (uv[:,0]>=0) & (uv[:,0]<width-1) & (uv[:,1]>=0) & (uv[:,1]<height-1)
    ids=np.flatnonzero(inside)
    # Visibility diagnostic: closest sparse point in each 4x4 native-pixel cell.
    # This does not alter, thin, or select the exported point cloud.
    cells=(uv[ids,1].astype(np.int64)//4)*((width+3)//4)+(uv[ids,0].astype(np.int64)//4)
    order=np.lexsort((ids,z[ids],cells))
    ids=ids[order];cells=cells[order]
    if len(ids):ids=ids[np.r_[True,cells[1:]!=cells[:-1]]]
    return uv,z,ids,int(np.count_nonzero(front)),int(np.count_nonzero(inside))

def bilinear(image,uv):
    x=np.floor(uv[:,0]).astype(np.int64);y=np.floor(uv[:,1]).astype(np.int64)
    ax=(uv[:,0]-x)[:,None];ay=(uv[:,1]-y)[:,None]
    return (image[y,x]*(1-ax)+image[y,x+1]*ax)*(1-ay)+(image[y+1,x]*(1-ax)+image[y+1,x+1]*ax)*ay

def measure(image,xyz,rgb,k,w2c,native_lens=None):
    height,width=image.shape[:2]
    uv,z,ids,front,inside=projected_visible(xyz,k,w2c,width,height,native_lens)
    result=dict(pointCount=len(xyz),inFront=front,inFrustum=inside,nearestPer4pxCell=len(ids),worldToCV=w2c.tolist())
    if len(ids):
        photo=bilinear(image,uv[ids]);colors=rgb[ids].astype(np.float64)
        error=np.mean(np.abs(photo-colors),axis=1)
        shuffled=np.random.default_rng(20261015).permutation(len(ids))
        chance=np.mean(np.abs(photo-colors[shuffled]),axis=1)
        p=photo-photo.mean(axis=0);q=colors-colors.mean(axis=0)
        denominator=np.sqrt(np.sum(p*p,axis=0)*np.sum(q*q,axis=0))
        correlations=np.divide(np.sum(p*q,axis=0),denominator,out=np.zeros(3),where=denominator>1e-12)
        result.update(meanRGBL1=float(error.mean()),medianRGBL1=float(np.median(error)),p90RGBL1=float(np.percentile(error,90)),
            shuffledMeanRGBL1=float(chance.mean()),shuffledImprovementRGB8=float(chance.mean()-error.mean()),
            RGBChannelCorrelation=correlations.tolist(),meanRGBChannelCorrelation=float(correlations.mean()),
            photoRGBStd=photo.std(axis=0).tolist(),pointRGBStd=colors.std(axis=0).tolist())
    return result,uv,ids

def decide(rows,views):
    # Predeclared conservative diagnostic acceptance. All three independent view
    # probes must agree; point colors must outperform their deterministic shuffle.
    eligible=[]
    for name,metrics in rows.items():
        if len(metrics)==len(views) and all(x.get('nearestPer4pxCell',0)>=100 and x.get('cameraRotationDeterminant',0)>=0.999 for x in metrics):
            eligible.append((float(np.mean([x['meanRGBL1'] for x in metrics])),name))
    eligible.sort()
    if not eligible:return dict(accepted=False,reasons=['No convention has at least 100 visible sparse points in every probe.'])
    score,name=eligible[0];runner=eligible[1] if len(eligible)>1 else None
    chosen=rows[name];reasons=[]
    if score>45:reasons.append('Photometric RGB8 error remains above diagnostic threshold45.')
    if runner is not None and runner[0]-score<5:reasons.append('Best-vs-runner RGB8 margin is below5; convention ambiguous.')
    if any(x['shuffledImprovementRGB8']<3 for x in chosen):reasons.append('At least one probe does not outperform shuffled colors by3RGB8.')
    if any(x['meanRGBChannelCorrelation']<0.2 for x in chosen):reasons.append('At least one probe has insufficient RGB correlation0.2.')
    if any(min(((m['meanRGBL1'],other) for other,ms in rows.items() for m in ms if m['viewIndex']==v and m.get('nearestPer4pxCell',0)>=100 and m.get('cameraRotationDeterminant',0)>=0.999 and m.get('meanRGBChannelCorrelation',-1)>=0.2 and m.get('shuffledImprovementRGB8',-1)>=3),default=(math.inf,''))[1]!=name for v in views):
        reasons.append('The independent views do not select the same convention.')
    if chosen[0]['cameraRotationDeterminant']<0.999:reasons.append('Winning camera rotation has a reflection; cannot export a COLMAP quaternion.')
    return dict(accepted=not reasons,selectedConvention=name,bestMeanRGBL1=score,runnerUp=runner,bestMinusRunnerMarginRGB8=None if runner is None else runner[0]-score,reasons=reasons,
        thresholdScope='Only evidence acceptance in this CPU diagnostic; no capture, resolution, population or product quota.')

def rotation_quaternion(r):
    # Select the largest stable quaternion component, including 180degrees.
    # Return COLMAP WXYZ with a deterministic quaternion sign.
    q=np.empty(4)
    trace=np.trace(r)
    if trace>0:
        s=math.sqrt(trace+1)*2;q[:]=[s/4,(r[2,1]-r[1,2])/s,(r[0,2]-r[2,0])/s,(r[1,0]-r[0,1])/s]
    else:
        i=int(np.argmax(np.diag(r)));j=(i+1)%3;k=(i+2)%3;s=math.sqrt(max(0,1+r[i,i]-r[j,j]-r[k,k]))*2
        q[0]=(r[k,j]-r[j,k])/s;q[i+1]=s/4;q[j+1]=(r[j,i]+r[i,j])/s;q[k+1]=(r[k,i]+r[i,k])/s
    q/=np.linalg.norm(q)
    if q[0]<0:q=-q
    return q

def clone_file(source,destination):
    destination.parent.mkdir(parents=True,exist_ok=True)
    cloned=False
    if sys.platform=='darwin':
        libc=ctypes.CDLL(None,use_errno=True);libc.clonefile.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int]
        cloned=libc.clonefile(os.fsencode(source),os.fsencode(destination),0)==0
    if not cloned:shutil.copyfile(source,destination)
    require(source.stat().st_ino!=destination.stat().st_ino or source.stat().st_dev!=destination.stat().st_dev,'Hard-linked source copy rejected.')

def distortion_reason(camera):
    distortion=camera.get('lensDistortion')
    if distortion is None:return None
    values=np.asarray(distortion.get('radialLookupTable',[]),np.float64)
    return 'Apple lens-distortion LUT is present; PINHOLE export cannot represent it exactly with byte-identical source photographs (no undocumented LUT approximation).' if len(values) and np.any(values!=0) else ('An Apple distortion payload is present but its empty/zero convention is not assumed to be identity.' if distortion else None)

def public_receipt(record):
    return {k:v for k,v in record.items() if not k.startswith('_')}

def cached_rectifications(directory):
    if directory is None:return {}
    document=json.loads((directory/'rectification-probes.json').read_text())
    return {row['frameID']:row for row in document['images']}

def checked_cached(record,frame,camera,expected_sha):
    require(record['frameID']==frame['id'] and record['sourceFile']==frame['rgbFile'] and record['sourceSHA256']==expected_sha,'Rectification cache has a mismatched original.')
    require(record['nativeIntrinsicsColumnMajor']==camera['intrinsicsColumnMajor'] and (record['width'],record['height'])==(frame['imageWidth'],frame['imageHeight']),'Rectification cache changed dimensions or K.')
    require(record['invalidMapPixelCount']==0 and record['maxRoundTripErrorPixels']<0.001 and record['validatedMapPixelCount']==frame['imageWidth']*frame['imageHeight'],'Rectification cache is not fully validated.')
    require(digest(Path(record['_path']))==record['rectifiedSHA256'],'Rectified probe PNG changed.')
    return record

def export_dataset(destination,source,manifest,frames,cameras,xyz,rgb,convention,provenance,
                   original_frames=None,rectification_records=None,workers=1,event_file=None,native_lut=False):
    require(not destination.exists(),'Dataset output already exists; no replacement is allowed.')
    destination.parent.mkdir(parents=True,exist_ok=True)
    stage=Path(tempfile.mkdtemp(prefix='.photogrammetry-calibrated-',dir=destination.parent))
    direction,signs=convention;rectified=rectification_records is not None;records={};original_frames=original_frames or frames
    try:
        if rectified:
            def process(frame):
                camera=cameras[frame['id']];original=safe_file(source,frame['rgbFile']);expected=provenance['inputSHA256'][str(original)]
                target=stage/'images'/(frame['id']+'.png')
                if frame['id'] in rectification_records:
                    row=checked_cached(rectification_records[frame['id']],frame,camera,expected)
                    clone_file(Path(row['_path']),target)
                    require(digest(target)==row['rectifiedSHA256'],'Copied rectified PNG changed.')
                    return row
                return rectify_frame(frame,camera,original,target,expected)
            with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                futures={pool.submit(process,frame):frame['id'] for frame in frames}
                for future in concurrent.futures.as_completed(futures):
                    row=future.result();records[row['frameID']]=row
                    if event_file:
                        with event_file.open('a') as f:f.write(json.dumps(dict(completed=len(records),total=len(frames),frameID=row['frameID'],cpuSeconds=row['cpuSeconds'],maxRoundTripErrorPixels=row['maxRoundTripErrorPixels']))+'\n')
                    if len(records)%25==0 or len(records)==len(frames):print(json.dumps(dict(event='rectified',completed=len(records),total=len(frames))),flush=True)
            require(len(records)==len(frames),'Some registered photographs were not rectified.')
        new_manifest=copy.deepcopy(manifest);new_manifest['frames']=[];new_manifest.pop('captureMetrics',None)
        new_manifest['units']='photogrammetryEstimatedUnits; metric scale unvalidated'
        new_manifest['cameraConvention']='Photogrammetry estimated CRS; cameraToWorld OpenGL right-handed -Z forward +Y up; native RGB top-left; axes validated by sparse RGB reprojection'
        new_manifest['matrixLayout']='columnMajor';new_manifest['photogrammetryCalibration']=provenance
        if native_lut:new_manifest.update(projectionKind='AppleNativeRadialLUT',requiresNativeLUTProjection=True,nativeGaussianCompatible=False)
        with (stage/'cameras.txt').open('w') as cf,(stage/'images.txt').open('w') as im:
            cf.write('# Native Apple estimated intrinsics. Native raster dimensions and K unchanged.\n')
            if native_lut:cf.write('# This is only the linear K base. Complete camera projection REQUIRES native-lut.json; NOT compatible with PINHOLE-only Gaussian training.\n')
            im.write('# World-to-camera COLMAP +Z forward +Y down; estimated photogrammetry CRS, not ARKit.\n')
            for index,frame in enumerate(frames,1):
                camera=cameras[frame['id']];native=matrix(camera['nativeTransformColumnMajor'],4);k=matrix(camera['intrinsicsColumnMajor'],3)
                w2c=world_to_cv(native,direction,signs);q=rotation_quaternion(w2c[:3,:3]);t=w2c[:3,3]
                cf.write(f"{index} PINHOLE {frame['imageWidth']} {frame['imageHeight']} {k[0,0]:.17g} {k[1,1]:.17g} {k[0,2]:.17g} {k[1,2]:.17g}\n")
                relative='images/'+frame['id']+'.png' if rectified else frame['rgbFile'];filename=Path(relative).name
                im.write(f"{index} "+' '.join(f'{x:.17g}' for x in [*q,*t])+f' {index} {filename}\n\n')
                if not rectified:
                    source_file=safe_file(source,frame['rgbFile']);target=stage/relative;clone_file(source_file,target)
                    require(digest(source_file)==digest(target),'A copied source photograph changed.')
                new_frame=copy.deepcopy(frame)
                for key in ('depthFile','confidenceFile','depthWidth','depthHeight'):new_frame.pop(key,None)
                if new_frame.get('sensorMetadata'):new_frame['sensorMetadata'].pop('depth',None)
                new_frame.update(rgbFile=relative,cameraToWorld=(np.linalg.inv(w2c)@FLIP_GL_CV).ravel(order='F').tolist(),intrinsics=k.ravel(order='F').tolist(),source='applePhotogrammetryRectifiedRGB' if rectified else ('applePhotogrammetryNativeLUT' if native_lut else 'applePhotogrammetryEstimatedCamera'))
                new_manifest['frames'].append(new_frame)
        with (stage/'points3D.txt').open('w') as f:
            f.write('# Every native Apple SfM point and native RGB8, in its estimated CRS. No LiDAR points/depth are mixed.\n')
            for i,(p,c) in enumerate(zip(xyz,rgb),1):f.write(f"{i} "+' '.join(f'{x:.17g}' for x in p)+' '+' '.join(str(int(x)) for x in c)+' 0\n')
        if rectified or native_lut:
            original_rows=[];registered={frame['id'] for frame in frames}
            for frame in original_frames:
                original=safe_file(source,frame['rgbFile']);posed=frame['id'] in registered
                archive=('source-originals/' if posed else 'unregistered-originals/')+frame['rgbFile'];target=stage/archive
                clone_file(original,target);expected=provenance['inputSHA256'][str(original)]
                require(digest(target)==expected,'An archived original differs from its original SHA.')
                original_rows.append(dict(frameID=frame['id'],sourceFile=frame['rgbFile'],sourceSHA256=expected,archivedFile=archive,status='registered' if posed else 'unregistered',reason='Native Apple estimated pose and K returned.' if posed else 'Apple returned no estimated pose; preserved original excluded only from calibrated training/retexturing inputs.'))
            dump(stage/'source-originals-registry.json',dict(schemaVersion=1,originalFrameCount=len(original_frames),registeredFrameCount=len(frames),unregisteredFrameCount=len(original_frames)-len(frames),images=original_rows))
            if rectified:
                dump(stage/'rectification.json',dict(schemaVersion=1,method='Apple LensDistortionData inverse radial LUT',appleSource=APPLE_LUT_SOURCE,images=[public_receipt(records[frame['id']]) for frame in frames],
                     nativeKAndCanvasUnchanged=True,allMapPixelsValidated=True,losslessPNG8Encoding=True,sourceOriginalsPreserved=True))
            if native_lut:
                lut_rows=[]
                for frame in frames:
                    camera=cameras[frame['id']];lens=camera['lensDistortion'];model=lens_model(camera,frame['imageWidth'],frame['imageHeight'])
                    lut_rows.append(dict(frameID=frame['id'],sourceFile=frame['rgbFile'],imageFile=frame['rgbFile'],width=frame['imageWidth'],height=frame['imageHeight'],intrinsicsColumnMajor=camera['intrinsicsColumnMajor'],center=lens['center'],radialLookupTable=lens['radialLookupTable'],radiusMax=model[2],lutSHA256=hashlib.sha256(json.dumps(lens,sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest(),sourceSHA256=provenance['inputSHA256'][str(source/frame['rgbFile'])]))
                dump(stage/'native-lut.json',dict(schemaVersion=1,projection='AppleNativeRadialLUT',formula='source=c+(pinhole-c)*(1+linearLUT(radius))',images=lut_rows,requiresNativeLUTProjection=True,nativeGaussianCompatible=False,sourceImagesByteIdentical=True,calibrationEvidence='Sparse RGB and independent source-to-Raw SIFT correspondences support this projection direction for these native Apple outputs; not a claim of physical scale or reconstruction accuracy.'))
            clone_file(Path(provenance['pointCloud']),stage/'photogrammetry-points-native.ply')
            clone_file(Path(provenance['calibration']),stage/'photogrammetry-cameras-native.json')
        dump(stage/'dataset.json',new_manifest);dump(stage/'calibration-provenance.json',provenance)
        require(len(new_manifest['frames'])==len(frames),'No registered frame may be silently removed.')
        for path,expected in provenance.get('inputSHA256',{}).items():
            require(digest(Path(path))==expected,'An original input changed before dataset publication: '+path)
        stage.rename(destination)
    finally:
        if stage.exists():shutil.rmtree(stage)
    return records

def run(args):
    started=time.perf_counter();source=args.source_dataset.resolve();calibration=args.calibration.resolve();point_file=args.point_cloud.resolve() if args.point_cloud else calibration.parent/'puntos.ply'
    require(not args.output.exists(),'Diagnostic output already exists; previous evidence is preserved.')
    args.output.mkdir(parents=True)
    manifest=json.loads((source/'dataset.json').read_text());frames=sorted(manifest['frames'],key=lambda f:(f['timestamp'],f['id']))
    native=json.loads(calibration.read_text());cameras={c['frameID']:c for c in native['cameras']}
    require(len(cameras)==len(native['cameras']),'Duplicate camera frameID in native calibration.')
    require(all(0<=v<len(frames) for v in args.views),'Probe view index is outside this capture.')
    inputs=[source/'dataset.json',calibration,point_file]+[safe_file(source,f['rgbFile']) for f in frames]
    hashes_before={str(p):digest(p) for p in inputs}
    xyz,rgb=read_points(point_file)
    rectify=bool(getattr(args,'rectify_native_lut',False));native_lut=bool(getattr(args,'native_lut_projection',False));allow_unregistered=bool(getattr(args,'allow_unregistered',False))
    require(not (rectify and native_lut),'Rectified PNG and native nonlinear JPEG representations are distinct explicit modes.')
    probe_cache=cached_rectifications(getattr(args,'rectification_probes',None));probe_records={};unregistered=[]
    problems=[];intrinsics_diagnostics=[]
    for frame in frames:
        camera=cameras.get(frame['id'])
        if camera is None:
            unregistered.append(dict(frameID=frame['id'],sourceFile=frame['rgbFile'],reason='Apple returned no estimated pose.'))
            if not allow_unregistered:problems.append(frame['id']+': no Apple estimated pose')
            continue
        if camera.get('sourceFile')!=frame['rgbFile']:problems.append(frame['id']+': source filename binding mismatch')
        k=camera.get('intrinsicsColumnMajor')
        if k is None:problems.append(frame['id']+': Apple intrinsics unavailable');continue
        k=matrix(k,3);pose=matrix(camera['nativeTransformColumnMajor'],4)
        source_k=matrix(frame['intrinsics'],3)
        intrinsics_diagnostics.append(dict(frameID=frame['id'],imageWidth=frame['imageWidth'],imageHeight=frame['imageHeight'],
            nativeIntrinsicsColumnMajor=k.ravel(order='F').tolist(),originalCaptureIntrinsicsColumnMajor=source_k.ravel(order='F').tolist(),
            focalRatiosToOriginalCapture=[float(k[0,0]/source_k[0,0]),float(k[1,1]/source_k[1,1])],
            principalPointInNativeRasterFraction=[float(k[0,2]/frame['imageWidth']),float(k[1,2]/frame['imageHeight'])],
            nativeLensDistortionPresent=camera.get('lensDistortion') is not None))
        require(np.max(np.abs(pose[3]-[0,0,0,1]))<1e-5 and np.max(np.abs(pose[:3,:3].T@pose[:3,:3]-np.eye(3)))<1e-3,'Native pose is not a finite rigid transform.')
        if max(abs(k[0,1]),abs(k[1,0]),abs(k[2,0]),abs(k[2,1]),abs(k[2,2]-1))>1e-6:problems.append(frame['id']+': non-PINHOLE intrinsics cannot be silently simplified')
        if k[0,0]<=0 or k[1,1]<=0:problems.append(frame['id']+': nonpositive native focal length')
        if rectify or native_lut:lens_model(camera,frame['imageWidth'],frame['imageHeight'])
        elif distortion_reason(camera):problems.append(frame['id']+': '+distortion_reason(camera))
        dims=(camera.get('inputImageWidth'),camera.get('inputImageHeight'))
        if dims!=(frame['imageWidth'],frame['imageHeight']):problems.append(frame['id']+': returned image dimensions differ or are unknown; no guessed K scale')
        if camera.get('inputImageOrientation') not in (None,1):problems.append(frame['id']+': image orientation requires explicit calibrated raster mapping')
    dump(args.output/'intrinsics-diagnostics.json',intrinsics_diagnostics)
    metrics={hypothesis_name(d,s):[] for d,s in hypotheses()}
    for view in args.views:
        frame=frames[view];camera=cameras.get(frame['id'])
        if camera is None or camera.get('intrinsicsColumnMajor') is None:continue
        path=safe_file(source,frame['rgbFile'])
        if rectify:
            expected=hashes_before[str(path)]
            if frame['id'] in probe_cache:record=checked_cached(probe_cache[frame['id']],frame,camera,expected)
            else:record=rectify_frame(frame,camera,path,args.output/'rectified-probes'/(frame['id']+'.png'),expected)
            probe_records[frame['id']]=record;path=Path(record['_path'])
        bgr=cv2.imread(str(path),cv2.IMREAD_COLOR|cv2.IMREAD_IGNORE_ORIENTATION);require(bgr is not None,'Cannot decode source photograph.')
        image=cv2.cvtColor(bgr,cv2.COLOR_BGR2RGB);height,width=image.shape[:2]
        require((width,height)==(frame['imageWidth'],frame['imageHeight']),'Native image dimensions disagree with capture manifest.')
        k=matrix(camera['intrinsicsColumnMajor'],3);pose=matrix(camera['nativeTransformColumnMajor'],4)
        per_view=[]
        active_lens=lens_model(camera,width,height) if native_lut else None
        for direction,signs in hypotheses():
            name=hypothesis_name(direction,signs);w2c=world_to_cv(pose,direction,signs)
            result,uv,ids=measure(image,xyz,rgb,k,w2c,active_lens);result.update(viewIndex=view,frameID=frame['id'],cameraRotationDeterminant=float(np.linalg.det(w2c[:3,:3])),convention=name)
            metrics[name].append(result);per_view.append(result)
        best=min((r for r in per_view if r.get('nearestPer4pxCell',0)>=100 and r.get('cameraRotationDeterminant',0)>=0.999 and r.get('meanRGBChannelCorrelation',-1)>=0.2 and r.get('shuffledImprovementRGB8',-1)>=3),key=lambda r:r.get('meanRGBL1',math.inf),default=None)
        if best:
            w2c=np.asarray(best['worldToCV']);uv,z,ids,_,_=projected_visible(xyz,k,w2c,width,height,active_lens)
            overlay=bgr.copy();points=np.rint(uv[ids]).astype(np.int32)
            for dy,dx in itertools.product((-1,0,1),repeat=2):
                px=np.clip(points[:,0]+dx,0,width-1);py=np.clip(points[:,1]+dy,0,height-1)
                overlay[py,px]=rgb[ids,::-1]
            label=f"Native SfM RGB overlay {view}: {best['convention']} L1={best['meanRGBL1']:.2f}; diagnostic only"
            cv2.putText(overlay,label,(30,55),cv2.FONT_HERSHEY_SIMPLEX,1.1,(0,0,0),5,cv2.LINE_AA);cv2.putText(overlay,label,(30,55),cv2.FONT_HERSHEY_SIMPLEX,1.1,(255,255,255),2,cv2.LINE_AA)
            require(cv2.imwrite(str(args.output/f'view-{view:05d}-native-overlay.png'),overlay),'Cannot write diagnostic overlay.')
        dump(args.output/f'view-{view:05d}-metrics.json',per_view)
    decision=decide(metrics,args.views)
    decision['physicalEligibility']='Only determinant >=0.999 rotations can win; reflected transforms remain diagnostic controls. Every per-view winner must also satisfy the existing RGB correlation>=0.2 and shuffle improvement>=3, uniformly across candidates. Aggregate45/margin5 and all numeric thresholds are unchanged.'
    decision['gateRevision']=2
    decision['gateChangeReason']='A lower MAE based on193 points with no correlation cannot beat9527 correlated points; uniform existing per-view evidence eligibility prevents this selection artifact.'
    if problems:decision['accepted']=False;decision['reasons'].append('Input calibration cannot safely represent the complete original capture; see inputProblems.')
    hashes_after={str(p):digest(p) for p in inputs};require(hashes_before==hashes_after,'An input changed during CPU validation.')
    report=dict(schemaVersion=1,mode='CPU sparse reprojection; no reconstruction/GPU/training',nativeIntrinsicsRescaled=False,photoRasterResized=False,
        sourceDataset=str(source),calibration=str(calibration),pointCloud=str(point_file),nativePointCount=len(xyz),sourceFrameCount=len(frames),nativeCameraCount=len(cameras),originalSourceFrameCount=len(frames),registeredFrameCount=len(cameras),unregisteredFrameCount=len(unregistered),unregisteredFrames=unregistered,
        evaluatedViews=args.views,decision=decision,inputProblems=problems,conventionMetrics=metrics,inputSHA256=hashes_before,inputsUnchanged=True,
        distortionPolicy=('Exact native nonlinear JPEG projection source=c+(pinhole-c)*(1+LUTinterp(radius)); no crop, remap, resize, K scaling or source edit. Not compatible with a PINHOLE-only Gaussian loader.' if native_lut else 'Apple LensDistortionData applied exactly via native inverse radial map to lossless PNG8; native K and dimensions unchanged; all original photographs archived.' if rectify else 'Native LUT preserved in calibration; no LUT-to-Brown fit or ignored LUT. Export blocked while non-nil distortion has no exact loader mapping.'),
        rectifiedProbeImages=[public_receipt(x) for x in probe_records.values()],
        projectionKind='AppleNativeRadialLUT' if native_lut else ('RectifiedPINHOLE' if rectify else 'UnrectifiedPINHOLEDiagnostic'),requiresNativeLUTProjection=native_lut,nativeGaussianCompatible=not native_lut,
        units='Photogrammetry estimated CRS; metric scale unvalidated',pointVisibilityPolicy='Closest sparse point per 4x4 native-pixel cell only for evidence. Every native point retained for any export.',
        limitations=['Same reconstruction input views; not held-out accuracy.','Point-cloud colors are multiview estimates; RGB agreement is a convention check, not a reconstruction quality benchmark.','Sparse z-buffer is not full mesh occlusion.','Pose output timing is Apple initial photogrammetric calculation, not guaranteed final bundle-adjustment iteration.'],cpuSeconds=time.perf_counter()-started)
    if args.export_dataset:
        if decision['accepted']:
            selected=next((d,s) for d,s in hypotheses() if hypothesis_name(d,s)==decision['selectedConvention'])
            provenance={k:report[k] for k in ('schemaVersion','sourceDataset','calibration','pointCloud','inputSHA256','units','distortionPolicy','decision')}
            registered_frames=[frame for frame in frames if frame['id'] in cameras]
            if native_lut:provenance.update(projectionKind='AppleNativeRadialLUT',requiresNativeLUTProjection=True,nativeGaussianCompatible=False,nativeLUTManifest='native-lut.json',sourceRegistryPath='source-originals-registry.json',nativePointCloud='photogrammetry-points-native.ply',nativeCalibration='photogrammetry-cameras-native.json',originalSourceFrameCount=len(frames),registeredFrameCount=len(registered_frames),unregisteredFrameCount=len(unregistered),nativeLUTPolicy=report['distortionPolicy'])
            if rectify:provenance.update(rectificationManifest='rectification.json',sourceOriginalsRegistry='source-originals-registry.json',nativePointCloud='photogrammetry-points-native.ply',nativeCalibration='photogrammetry-cameras-native.json',originalSourceFrameCount=len(frames),registeredFrameCount=len(registered_frames),unregisteredFrameCount=len(unregistered))
            export_dataset(args.export_dataset.resolve(),source,manifest,registered_frames,cameras,xyz,rgb,selected,provenance,original_frames=frames,rectification_records=probe_records if rectify else None,workers=getattr(args,'workers',1),event_file=args.output/'rectification-events.ndjson',native_lut=native_lut)
            report['exportedDataset']=str(args.export_dataset.resolve());report['exportedAllRegisteredFrames']=True;report['exportedAllSourceFrames']=len(registered_frames)==len(frames);report['exportedAllNativePoints']=True
            report['exportedDatasetSHA256']={name:digest(args.export_dataset/name) for name in ['dataset.json','cameras.txt','images.txt','points3D.txt','calibration-provenance.json']+(['rectification.json','source-originals-registry.json','photogrammetry-points-native.ply','photogrammetry-cameras-native.json'] if rectify else (['native-lut.json','source-originals-registry.json','photogrammetry-points-native.ply','photogrammetry-cameras-native.json'] if native_lut else []))}
        else:report['exportedDataset']=None
    dump(args.output/'report.json',report)
    print(json.dumps(dict(decision=decision,inputProblemCount=len(problems),points=len(xyz),frames=len(frames),exportedDataset=report.get('exportedDataset'),report=str(args.output/'report.json')),indent=2))

def self_test():
    width,height=320,240;k=np.array([[210.,0,160.],[0,210.,120.],[0,0,1.]])
    yy,xx=np.mgrid[0:height,0:width];image=np.stack([(xx*7+yy*3)%256,(xx*2+yy*11)%256,(xx*13+yy*5)%256],axis=-1).astype(np.uint8)
    py,px=np.mgrid[12:height-12:4,12:width-12:4];uv=np.column_stack([px.ravel(),py.ravel()]).astype(float);z=np.full(len(uv),3.)
    xyz=np.column_stack([(uv[:,0]-160)*z/210,-(uv[:,1]-120)*z/210,-z]);rgb=bilinear(image,uv).astype(np.uint8)
    rows={}
    for d,s in hypotheses():
        metric,_,_=measure(image,xyz,rgb,k,world_to_cv(np.eye(4),d,s));metric.update(viewIndex=0,cameraRotationDeterminant=float(np.prod(s)));rows[hypothesis_name(d,s)]=[metric]
    # At an identity transform C2W and W2C are indistinguishable: fail closed.
    require(not decide(rows,[0])['accepted'],'Identity direction ambiguity must reject export.')
    p=np.eye(4);p[:3,3]=[.21,-.13,.04]
    _,_,ids,_,_=projected_visible(xyz,k,world_to_cv(p,'C2W',(1,-1,-1)),width,height)
    require(len(ids)>100,'Synthetic projection must preserve visible support.')
    q=rotation_quaternion(np.diag([-1.,1.,-1.]));require(np.max(np.abs(q-[0,0,1,0]))<1e-12,'180degree COLMAP quaternion failed.')
    require(distortion_reason({'lensDistortion':{'center':[1,2],'radialLookupTable':[.1,.2]}}) is not None,'Unrepresented LUT must reject export.')
    # A second fixture has nonidentity poses and a physically shared colored
    # world plane. This must resolve both transform direction and optical axes.
    def color(world):
        x,y=world[...,0],world[...,1]
        return np.stack([125+95*np.sin(2.1*x+.7*y),125+90*np.cos(1.4*y-.5*x),125+85*np.sin(1.3*x-2.3*y)],axis=-1)
    native_cameras=[];observations=[]
    for i,(tx,ty,angle) in enumerate(((.24,-.18,.11),(-.32,.21,-.13),(.15,.25,.16))):
        c,sn=math.cos(angle),math.sin(angle);pose=np.eye(4);pose[:3,:3]=[[c,0,sn],[0,1,0],[-sn,0,c]];pose[:3,3]=[tx,ty,.07]
        rays=np.stack([(xx-160)/210,-(yy-120)/210,-np.ones_like(xx)],axis=-1)
        world_rays=np.einsum('...i,ji->...j',rays,pose[:3,:3],optimize=False)
        amount=(-3-pose[2,3])/world_rays[...,2]
        world=pose[:3,3]+world_rays*amount[...,None]
        observations.append(np.clip(np.rint(color(world)),0,255).astype(np.uint8));native_cameras.append(pose)
    colors=np.clip(np.rint(color(xyz)),0,255).astype(np.uint8)
    resolved={hypothesis_name(d,s):[] for d,s in hypotheses()}
    for i,(photo,pose) in enumerate(zip(observations,native_cameras)):
        for d,s in hypotheses():
            w=world_to_cv(pose,d,s);metric,_,_=measure(photo,xyz,colors,k,w)
            metric.update(viewIndex=i,cameraRotationDeterminant=float(np.linalg.det(w[:3,:3])))
            resolved[hypothesis_name(d,s)].append(metric)
    accepted=decide(resolved,[0,1,2]);require(accepted['accepted'] and accepted['selectedConvention']=='C2W_+--','Authored calibrated scene did not uniquely resolve native OpenGL C2W: '+str(accepted))
    with tempfile.TemporaryDirectory(prefix='forma-calibrated-test-') as temporary:
        base=Path(temporary);source=base/'source';source.mkdir();frames=[];cameras={}
        for i,(photo,pose) in enumerate(zip(observations,native_cameras)):
            name=f'images/fixture-{i}.png';(source/'images').mkdir(exist_ok=True);require(cv2.imwrite(str(source/name),photo[...,::-1]),'Fixture PNG write failed.')
            frame=dict(id=f'fixture-{i}',rgbFile=name,timestamp=i,imageWidth=width,imageHeight=height,cameraToWorld=np.eye(4).ravel(order='F').tolist(),intrinsics=k.ravel(order='F').tolist(),source='syntheticARKit',depthFile='depth/must-not-copy.f32',confidenceFile='confidence/must-not-copy.u8',depthWidth=2,depthHeight=2)
            frames.append(frame);cameras[frame['id']]=dict(nativeTransformColumnMajor=pose.ravel(order='F').tolist(),intrinsicsColumnMajor=k.ravel(order='F').tolist())
        output=base/'dataset'
        export_dataset(output,source,dict(schemaVersion=1,frames=frames,units='meters'),frames,cameras,xyz,colors,('C2W',(1,-1,-1)),dict(test='synthetic-only'))
        loaded=json.loads((output/'dataset.json').read_text());require(len(loaded['frames'])==3,'Synthetic export omitted a frame.')
        require('estimated' in loaded['units'].lower(),'Synthetic export incorrectly declared validated metric scale.')
        for old,new in zip(frames,loaded['frames']):
            require(digest(source/old['rgbFile'])==digest(output/new['rgbFile']),'Synthetic photo bytes changed.')
            require(not any(x in new for x in ('depthFile','confidenceFile','depthWidth','depthHeight')),'ARKit depth leaked into SfM dataset.')
            require(np.max(np.abs(matrix(new['cameraToWorld'],4)-native_cameras[int(new['id'].split('-')[-1])]))<1e-12,'Exported camera differs from known native GL pose.')
        require(sum(1 for row in (output/'points3D.txt').read_text().splitlines() if row and not row.startswith('#'))==len(xyz),'Synthetic export truncated native points.')
        dump(source/'dataset.json',dict(schemaVersion=1,frames=frames,units='meters'))
        camera_rows=[]
        for frame in frames:
            camera_rows.append(dict(frameID=frame['id'],sourceFile=frame['rgbFile'],inputImageWidth=width,inputImageHeight=height,inputImageOrientation=1,**cameras[frame['id']]))
        calibration=base/'cámaras.json';dump(calibration,dict(schemaVersion=1,cameras=camera_rows))
        point_file=base/'puntos.ply'
        with point_file.open('w') as f:
            f.write(f'ply\nformat ascii 1.0\ncomment synthetic CPU fixture only\nelement vertex {len(xyz)}\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\nend_header\n')
            for p,c in zip(xyz,colors):f.write(' '.join(str(float(x)) for x in p)+' '+' '.join(str(int(x)) for x in c)+' 255\n')
        run(argparse.Namespace(calibration=calibration,point_cloud=point_file,source_dataset=source,output=base/'evidence',views=[0,1,2],export_dataset=base/'validated'))
        actual=json.loads((base/'evidence/report.json').read_text())
        require(actual['decision']['accepted'] and actual['inputsUnchanged'] and actual['exportedAllNativePoints'],'End-to-end calibration fixture failed.')
        require(len(list((base/'evidence').glob('*-native-overlay.png')))==3,'End-to-end calibration omitted an overlay.')
    print('PASS CPU native rays, direction/axis convention, ambiguity rejection, quaternion180, LUT rejection and full COLMAP export with independent byte-identical photos/all points/no ARKit depth; no GPU/native engine invoked.')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--calibration',type=Path);parser.add_argument('--point-cloud',type=Path);parser.add_argument('--source-dataset',type=Path)
    parser.add_argument('--output',type=Path);parser.add_argument('--views',type=int,nargs='+',default=[0,283,565]);parser.add_argument('--export-dataset',type=Path)
    parser.add_argument('--rectify-native-lut',action='store_true');parser.add_argument('--allow-unregistered',action='store_true');parser.add_argument('--native-lut-projection',action='store_true')
    parser.add_argument('--rectification-probes',type=Path);parser.add_argument('--workers',type=int,default=min(8,os.cpu_count() or 1))
    parser.add_argument('--self-test',action='store_true');args=parser.parse_args()
    require(args.workers>=1,'At least one CPU worker is required.')
    if args.self_test:self_test();return
    require(args.calibration and args.source_dataset and args.output,'--calibration, --source-dataset and --output are required.')
    run(args)
if __name__=='__main__':main()
