"""CPU implementation of Apple's published LensDistortionData radial map.

Source: https://developer.apple.com/documentation/realitykit/lensdistortiondata.md
The LUT is used directly, not fitted to a Brown/conventional lens polynomial.
"""
from pathlib import Path
import hashlib, json, math, struct, time, zlib
import cv2
import numpy as np

APPLE_LUT_SOURCE='https://developer.apple.com/documentation/realitykit/lensdistortiondata.md'

def require(ok,message):
    if not ok:raise ValueError(message)

def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
    return h.hexdigest()

def lens_model(camera,width,height):
    lens=camera.get('lensDistortion')
    require(lens is not None,'Native lens distortion is missing; this explicit rectification path expects Apple LUT data.')
    center=np.asarray(lens['center'],np.float64);lut=np.asarray(lens['radialLookupTable'],np.float64)
    require(center.shape==(2,) and len(lut)>=2 and np.isfinite(center).all() and np.isfinite(lut).all(),'Invalid native Apple lens LUT.')
    require(0<=center[0]<=width-1 and 0<=center[1]<=height-1,'Optical center is outside the native image.')
    dx=max(center[0],width-center[0]);dy=max(center[1],height-center[1]);rmax=math.hypot(dx,dy)
    radii=np.linspace(0,rmax,len(lut),dtype=np.float64)
    rectified_radii=radii*(1+lut)
    slopes=np.diff(lut)/np.diff(radii)
    intercepts=1+lut[:-1]-slopes*radii[:-1]
    derivative_start=intercepts+2*slopes*radii[:-1]
    derivative_end=intercepts+2*slopes*radii[1:]
    require(np.all(np.diff(rectified_radii)>0) and np.all(derivative_start>0) and np.all(derivative_end>0),'Apple radial map is not monotonically invertible; no derived image was invented.')
    require(np.all(lut>=0),'Negative native LUT may produce unsupported output pixels; this verified native-canvas path rejects it.')
    return center,lut,rmax,radii,rectified_radii,slopes,intercepts

def inverse_radius(q,model):
    center,lut,rmax,radii,rectified_radii,slopes,intercepts=model
    require(np.max(q)<=rectified_radii[-1]+1e-9,'Requested output radius lies outside the native radial map.')
    segment=np.searchsorted(rectified_radii,q,side='right')-1
    segment=np.clip(segment,0,len(slopes)-1)
    a=slopes[segment];b=intercepts[segment]
    discriminant=b*b+4*a*q
    require(np.all(discriminant>=0),'Native radial inversion has no real solution.')
    denominator=b+np.sqrt(discriminant)
    require(np.all(denominator>0),'Native radial inversion is numerically singular.')
    # Exact stable inverse of each segment r*(1+linearLUT(r)). This solves
    # Apple's piecewise quadratic map; it is not a polynomial lens fit.
    return 2*q/denominator

def forward_xy(x,y,model):
    center,lut,rmax,*_=model
    dx=x-center[0];dy=y-center[1];radius=np.hypot(dx,dy)
    value=radius*(len(lut)-1)/rmax
    index=np.minimum(np.floor(value).astype(np.int64),len(lut)-2)
    fraction=np.clip(value-index,0,1)
    magnification=(1-fraction)*lut[index]+fraction*lut[index+1]
    return center[0]+dx*(1+magnification),center[1]+dy*(1+magnification)

def bilinear_rows(image,x,y):
    height,width=image.shape[:2]
    left=np.floor(x).astype(np.int64);top=np.floor(y).astype(np.int64)
    right=np.minimum(left+1,width-1);bottom=np.minimum(top+1,height-1)
    ax=(x-left)[...,None];ay=(y-top)[...,None]
    value=(image[top,left]*(1-ax)+image[top,right]*ax)*(1-ay)+(image[bottom,left]*(1-ax)+image[bottom,right]*ax)*ay
    return np.clip(np.rint(value),0,255).astype(np.uint8)

def write_srgb_png(path,image):
    success,encoded=cv2.imencode('.png',image,[cv2.IMWRITE_PNG_COMPRESSION,1])
    require(success,'Could not encode lossless PNG8.')
    raw=encoded.tobytes();require(raw[:8]==b'\x89PNG\r\n\x1a\n' and raw[12:16]==b'IHDR','Invalid encoded PNG.')
    # Source RGBDRecording writes native JPEG in explicit sRGB. Preserve that
    # interpretation in the losslessly encoded, geometrically resampled raster.
    chunk_type=b'sRGB';payload=b'\0'
    chunk=struct.pack('>I',1)+chunk_type+payload+struct.pack('>I',zlib.crc32(chunk_type+payload)&0xffffffff)
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('xb') as f:f.write(raw[:33]);f.write(chunk);f.write(raw[33:])

def rectify_frame(frame,camera,source_file,destination,source_sha):
    started=time.perf_counter();width,height=frame['imageWidth'],frame['imageHeight']
    require(not destination.exists(),'Rectification output already exists; source and earlier evidence are preserved.')
    require(digest(source_file)==source_sha,'Original photo changed before rectification.')
    image=cv2.imread(str(source_file),cv2.IMREAD_COLOR|cv2.IMREAD_IGNORE_ORIENTATION)
    require(image is not None and image.shape==(height,width,3),'Native photo raster dimensions do not match calibration.')
    model=lens_model(camera,width,height);center,lut,rmax,*_=model
    output=np.empty_like(image);columns=np.arange(width,dtype=np.float64)[None,:]
    max_error=0.;min_x=math.inf;max_x=-math.inf;min_y=math.inf;max_y=-math.inf;validated=0
    corners=[]
    for first in range(0,height,128):
        rows=np.arange(first,min(first+128,height),dtype=np.float64)[:,None]
        dx=columns-center[0];dy=rows-center[1];q=np.hypot(dx,dy)
        radius=inverse_radius(q,model)
        scale=np.divide(radius,q,out=np.ones_like(radius),where=q>0)
        x=center[0]+dx*scale;y=center[1]+dy*scale
        invalid=(~np.isfinite(x))|(~np.isfinite(y))|(x<0)|(x>width-1)|(y<0)|(y>height-1)
        require(not np.any(invalid),'The complete inverse map contains invalid source coordinates; no black/out-of-bounds pixels are allowed.')
        forward_x,forward_y=forward_xy(x,y,model)
        error=np.hypot(forward_x-columns,forward_y-rows)
        max_error=max(max_error,float(np.max(error)))
        require(max_error<0.001,'Native inverse radial roundtrip is not accurate to0.001pixel.')
        min_x=min(min_x,float(x.min()));max_x=max(max_x,float(x.max()));min_y=min(min_y,float(y.min()));max_y=max(max_y,float(y.max()))
        output[first:first+len(rows)]=bilinear_rows(image,x,y)
        validated+=x.size
        if first==0:corners.extend([[float(x[0,0]),float(y[0,0])],[float(x[0,-1]),float(y[0,-1])]])
        if first+len(rows)==height:corners.extend([[float(x[-1,0]),float(y[-1,0])],[float(x[-1,-1]),float(y[-1,-1])]])
    require(validated==width*height,'Not every output pixel was validated.')
    write_srgb_png(destination,output)
    # Verify the lossless PNG roundtrip, not just successful encoding.
    reloaded=cv2.imread(str(destination),cv2.IMREAD_COLOR|cv2.IMREAD_IGNORE_ORIENTATION)
    require(reloaded is not None and np.array_equal(output,reloaded),'Rectified PNG did not preserve its RGB8 pixels losslessly.')
    require(digest(source_file)==source_sha,'Original photo changed during rectification.')
    lens=camera['lensDistortion']
    lut_sha=hashlib.sha256(json.dumps(lens,sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest()
    return dict(frameID=frame['id'],sourceFile=frame['rgbFile'],sourceSHA256=source_sha,rectifiedFile='images/'+frame['id']+'.png',rectifiedSHA256=digest(destination),
        width=width,height=height,nativeIntrinsicsColumnMajor=camera['intrinsicsColumnMajor'],maxRoundTripErrorPixels=max_error,invalidMapPixelCount=0,
        validatedMapPixelCount=validated,lutSHA256=lut_sha,lutCount=len(lut),sourceMapBounds=[min_x,min_y,max_x,max_y],outputCornersInOriginalPixels=corners,
        mapping='Apple distorted p -> rectified q=center+(p-center)*(1+LUT(r)); output q samples original inverse p',
        inverse='Stable exact inverse of each piecewise-linear LUT radial-magnification segment; no Brown model fit',
        interpolation='Float64 bilinear interpolation of decoded sRGB8, rounded once toRGB8; PNG8 lossless encoding',
        nativeCanvasAndIntrinsicsUnchanged=True,fieldOfViewNote='Same native dimensions and K. Nonnegative outward distortion means the rectified native canvas samples inward of the original distorted boundaries; the original broader peripheral content is archived, not black-filled or silently discarded.',
        appleSource=APPLE_LUT_SOURCE,cpuSeconds=time.perf_counter()-started,_path=str(destination))
