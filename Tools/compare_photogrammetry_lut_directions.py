#!/usr/bin/env python3
"""CPU-only negative control: compare native/Apple inverse/opposite LUT sampling.
No training dataset, black border, reconstruction, GPU, or source edit is produced.
"""
from pathlib import Path
import argparse, hashlib, json
import numpy as np
import cv2
from photogrammetry_calibrated_dataset import matrix, world_to_cv, projected_visible, bilinear, digest, dump, safe_file
from photogrammetry_rectification import lens_model, forward_xy, inverse_radius

def comparison(source,calibration,cloud,output):
    from photogrammetry_calibrated_dataset import read_points
    if output.exists():raise ValueError('Prior control evidence is preserved; choose a new output.')
    output.mkdir(parents=True)
    frames=sorted(json.loads((source/'dataset.json').read_text())['frames'],key=lambda x:(x['timestamp'],x['id']))
    cameras={x['frameID']:x for x in json.loads(calibration.read_text())['cameras']};xyz,rgb=read_points(cloud)
    inputs=[source/'dataset.json',calibration,cloud]+[safe_file(source,frames[i]['rgbFile']) for i in (0,283,565)]
    before={str(p):digest(p) for p in inputs};views=[]
    for view in (0,283,565):
        frame=frames[view];camera=cameras[frame['id']];width,height=frame['imageWidth'],frame['imageHeight']
        image=cv2.cvtColor(cv2.imread(str(source/frame['rgbFile']),cv2.IMREAD_COLOR|cv2.IMREAD_IGNORE_ORIENTATION),cv2.COLOR_BGR2RGB)
        model=lens_model(camera,width,height);center=model[0];k=matrix(camera['intrinsicsColumnMajor'],3)
        w=world_to_cv(matrix(camera['nativeTransformColumnMajor'],4),'C2W',(1,-1,-1))
        uv,z,ids,front,frustum=projected_visible(xyz,k,w,width,height);q=uv[ids]
        delta=q-center;radius=np.hypot(delta[:,0],delta[:,1]);p_radius=inverse_radius(radius,model)
        scale=np.divide(p_radius,radius,out=np.ones_like(radius),where=radius>0)
        inverse=center+delta*scale[:,None]
        fx,fy=forward_xy(q[:,0],q[:,1],model);opposite=np.column_stack([fx,fy])
        modes={'originalNoWarp':q,'appleDocumentedUndistortInverseSampling':inverse,'oppositeForwardSamplingControl':opposite}
        validity={name:((p[:,0]>=0)&(p[:,0]<width-1)&(p[:,1]>=0)&(p[:,1]<height-1)) for name,p in modes.items()}
        common=np.logical_and.reduce(list(validity.values()));common_ids=ids[common];colors=rgb[common_ids].astype(float)
        stats={}
        for name,p in modes.items():
            sampled=bilinear(image,p[common]);error=np.abs(sampled-colors).mean(axis=1)
            chance=np.abs(sampled-colors[np.random.default_rng(20261015).permutation(len(colors))]).mean(axis=1)
            a=sampled-sampled.mean(axis=0);b=colors-colors.mean(axis=0);denom=np.sqrt((a*a).sum(axis=0)*(b*b).sum(axis=0));corr=np.divide((a*b).sum(axis=0),denom,out=np.zeros(3),where=denom>1e-12)
            stats[name]=dict(meanRGBL1=float(error.mean()),medianRGBL1=float(np.median(error)),meanRGBCorrelation=float(corr.mean()),shuffledImprovementRGB8=float(chance.mean()-error.mean()),invalidProjectedPointsBeforeCommonSupport=int(np.count_nonzero(~validity[name])))
        invalid=0
        columns=np.arange(width,dtype=float)[None,:]
        for first in range(0,height,128):
            rows=np.arange(first,min(first+128,height),dtype=float)[:,None]
            x,y=forward_xy(columns,rows,model)
            invalid+=int(np.count_nonzero((x<0)|(x>width-1)|(y<0)|(y>height-1)))
        views.append(dict(viewIndex=view,frameID=frame['id'],width=width,height=height,nearestVisiblePoints=len(ids),commonValidPoints=len(common_ids),
            commonPointIDsSHA256=hashlib.sha256(common_ids.astype('<i8').tobytes()).hexdigest(),modes=stats,oppositeFullNativeCanvasInvalidPixelCount=invalid,
            noOppositeImageWritten='Opposite sampling leaves the source canvas at the boundaries; no black or clamped source pixels were invented.'))
    after={str(p):digest(p) for p in inputs}
    if before!=after:raise ValueError('An original changed during the CPU control.')
    report=dict(schemaVersion=1,purpose='LUT direction negative control on identical common sparse point support; not a quality benchmark or approval',
        geometryConvention='C2W OpenGL converted by diag(1,-1,-1) for projection',nativeIntrinsicsAndRasterUnchanged=True,views=views,inputSHA256=before,inputsUnchanged=True,
        limitations=['Sparse multiview point colors and incomplete occlusion are not exact per-image color targets.','Geometric photo-to-Raw correspondences are required to determine LUT semantics independently.'],exportedDataset=None)
    dump(output/'report.json',report);print(json.dumps(views,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source-dataset',type=Path,required=True);p.add_argument('--calibration',type=Path,required=True);p.add_argument('--point-cloud',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    comparison(a.source_dataset.resolve(),a.calibration.resolve(),a.point_cloud.resolve(),a.output)
