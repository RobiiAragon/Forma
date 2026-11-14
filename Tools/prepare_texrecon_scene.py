#!/usr/bin/env python3
"""CPU-only adapter: an accepted Photogrammetry COLMAP dataset -> byte-exact JPEG/PNG + CAM.
Never runs texrecon. Never changes photographs, geometry or the calibrated dataset.
"""
from pathlib import Path, PurePosixPath
import argparse
import ctypes
import hashlib
import json
import math
import os
import shutil
import struct
import sys
import tempfile
import time


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def dump(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def safe_relative(name):
    require(isinstance(name, str) and name and '\x00' not in name and '\\' not in name and ':' not in name,
            'Unsafe relative image path.')
    pieces = name.split('/')
    require(not name.startswith('/') and all(p not in ('', '.', '..') for p in pieces), 'Unsafe relative image path.')
    return PurePosixPath(name)


def safe_file(root, relative):
    path = root
    for piece in safe_relative(relative).parts:
        path = path / piece
        require(not path.is_symlink(), 'Image/metadata symlink is not allowed: ' + str(path))
    require(path.is_file(), 'Missing regular file: ' + str(path))
    require(path.resolve().is_relative_to(root.resolve()), 'File escapes the calibrated dataset.')
    return path


def finite(values, label):
    require(all(math.isfinite(x) for x in values), 'Nonfinite ' + label)


def quaternion_rotation(q):
    finite(q, 'quaternion')
    norm = math.sqrt(sum(v * v for v in q))
    require(abs(norm - 1) < 1e-4, 'COLMAP quaternion is not unit length.')
    w, x, y, z = (v / norm for v in q)
    return [[1 - 2 * (y*y + z*z), 2 * (x*y - z*w), 2 * (x*z + y*w)],
            [2 * (x*y + z*w), 1 - 2 * (x*x + z*z), 2 * (y*z - x*w)],
            [2 * (x*z - y*w), 2 * (y*z + x*w), 1 - 2 * (x*x + y*y)]]


def mv(a, b):
    return [sum(x*y for x, y in zip(row, b)) for row in a]


def load_cameras(path):
    cameras = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split()
        require(len(fields) == 8 and fields[1] == 'PINHOLE', 'Only exact PINHOLE fx/fy/cx/cy cameras are supported; no silent distortion/skew approximation.')
        ident, width, height = int(fields[0]), int(fields[2]), int(fields[3])
        k = list(map(float, fields[4:8])); finite(k, 'intrinsics')
        require(ident > 0 and ident not in cameras and width > 0 and height > 0 and k[0] > 0 and k[1] > 0, 'Invalid or duplicate camera.')
        cameras[ident] = dict(width=width, height=height, fx=k[0], fy=k[1], cx=k[2], cy=k[3])
    require(cameras, 'No COLMAP cameras.')
    return cameras


def load_images(path):
    images = []; ids = set(); names = set()
    lines = iter(path.read_text().splitlines())
    for line in lines:
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split(maxsplit=9)
        require(len(fields) == 10, 'Malformed COLMAP image header.')
        ident = int(fields[0]); camera_id = int(fields[8]); name = fields[9]
        safe_relative(name)
        require(ident > 0 and ident not in ids and name not in names, 'Duplicate/invalid COLMAP image identity.')
        q = list(map(float, fields[1:5])); t = list(map(float, fields[5:8])); finite(t, 'translation')
        r = quaternion_rotation(q)
        # Consume POINTS2D row even if empty. The input loader must not reinterpret it as a camera.
        observations = next(lines, None)
        require(observations is not None, 'Missing COLMAP POINTS2D row.')
        require(not observations.strip() or len(observations.split()) % 3 == 0, 'Malformed COLMAP POINTS2D row.')
        ids.add(ident); names.add(name)
        images.append(dict(imageID=ident, cameraID=camera_id, name=name, q=q, t=t, R=r))
    require(images, 'No COLMAP images.')
    return images


def jpeg_dimensions(path):
    # Reads native SOF dimensions only: no EXIF autorotation, resampling or color conversion.
    with path.open('rb') as f:
        require(f.read(2) == b'\xff\xd8', 'Referenced image is not JPEG: ' + str(path))
        while True:
            byte = f.read(1)
            require(byte, 'JPEG has no SOF dimensions.')
            if byte != b'\xff':
                continue
            marker = f.read(1)
            while marker == b'\xff':
                marker = f.read(1)
            require(marker, 'Truncated JPEG marker.')
            code = marker[0]
            if code in (0xD8, 0x01) or 0xD0 <= code <= 0xD7:
                continue
            require(code not in (0xD9, 0xDA), 'JPEG dimensions missing before image scan.')
            size = f.read(2); require(len(size) == 2, 'Truncated JPEG segment.')
            size = struct.unpack('>H', size)[0]; require(size >= 2, 'Invalid JPEG segment.')
            if code in (0xC0,0xC1,0xC2,0xC3,0xC5,0xC6,0xC7,0xC9,0xCA,0xCB,0xCD,0xCE,0xCF):
                payload = f.read(5); require(len(payload) == 5, 'Truncated JPEG SOF.')
                height, width = struct.unpack('>HH', payload[1:5]); require(width > 0 and height > 0, 'Invalid JPEG dimensions.')
                return width, height
            f.seek(size - 2, 1)


def image_dimensions(path):
    if path.suffix.lower() in ('.jpg', '.jpeg'):
        return jpeg_dimensions(path)
    require(path.suffix.lower() == '.png', 'Only JPEG or explicitly rectified PNG is supported.')
    with path.open('rb') as f:
        header = f.read(24)
    require(len(header) == 24 and header[:8] == b'\x89PNG\r\n\x1a\n' and header[8:16] == b'\x00\x00\x00\rIHDR', 'Invalid PNG header.')
    width, height = struct.unpack('>II', header[16:24])
    require(width > 0 and height > 0, 'Invalid PNG dimensions.')
    return width, height


def originals_context(dataset, provenance, report, frames):
    """Account for every original observation, including those without a recovered pose."""
    registry_path = provenance.get('sourceOriginalsRegistry') or provenance.get('sourceRegistryPath')
    require(registry_path, 'Missing original-image registry path.')
    registry_file = safe_file(dataset, registry_path)
    registry = json.loads(registry_file.read_text())
    require(registry.get('schemaVersion') == 1, 'Unsupported original-image registry.')
    originals = {}; unregistered = []
    for entry in registry['images']:
        ident = entry['frameID']; require(ident not in originals, 'Duplicate original frame registry entry.')
        require(entry.get('status') in ('registered', 'unregistered'), 'Original frame has no explicit registration status.')
        archived = safe_file(dataset, entry['archivedFile'])
        expected = provenance['inputSHA256'].get(str(Path(provenance['sourceDataset']) / str(safe_relative(entry['sourceFile']))))
        require(expected == entry['sourceSHA256'] and digest(archived) == expected, 'An archived original differs from the validated capture.')
        originals[ident] = entry
        if entry['status'] == 'unregistered':
            require(isinstance(entry.get('reason'), str) and entry['reason'].strip(), 'Unregistered original needs its explicit reason.')
            unregistered.append(entry)
    registered_ids = {ident for ident, entry in originals.items() if entry['status'] == 'registered'}
    require(len(originals) == registry.get('originalFrameCount') == report.get('originalSourceFrameCount'), 'Original frame accounting mismatch.')
    require(len(registered_ids) == registry.get('registeredFrameCount') == report.get('registeredFrameCount') == len(frames), 'Registered frame accounting mismatch.')
    require(len(unregistered) == registry.get('unregisteredFrameCount') == report.get('unregisteredFrameCount'), 'Unregistered frame accounting mismatch.')
    require(len(originals) == len(registered_ids) + len(unregistered), 'Some original observations were silently omitted.')
    require({f['id'] for f in frames} == registered_ids, 'Prepared manifest does not cover exactly the registered observations.')
    return dict(originals=originals, unregistered=unregistered, registeredIDs=registered_ids,
                registrySHA256=digest(registry_file), originalCount=len(originals), registeredCount=len(registered_ids))


def rectification_context(dataset, provenance, report, frames):
    """Validate the published image derivation and account for every original observation."""
    context = originals_context(dataset, provenance, report, frames)
    rect_file = safe_file(dataset, provenance['rectificationManifest'])
    rect = json.loads(rect_file.read_text())
    require(rect.get('schemaVersion') == 1 and rect.get('method') == 'Apple LensDistortionData inverse radial LUT', 'Unsupported rectification provenance.')
    originals = context['originals']; registered_ids = context['registeredIDs']; rectified = {}
    for entry in rect['images']:
        ident = entry['frameID']; require(ident in registered_ids and ident not in rectified, 'Unknown or duplicate rectified frame.')
        original = originals[ident]
        require(entry['sourceFile'] == original['sourceFile'] and entry['sourceSHA256'] == original['sourceSHA256'], 'Rectification lost its original-image binding.')
        require(entry.get('invalidMapPixelCount') == 0, 'Rectification map has unobserved/black-fill pixels.')
        error = entry.get('maxRoundTripErrorPixels')
        require(isinstance(error, (int, float)) and math.isfinite(error) and error >= 0, 'Rectification round-trip evidence is invalid.')
        lut_sha = entry.get('lutSHA256')
        require(isinstance(lut_sha, str) and len(lut_sha) == 64 and all(c in '0123456789abcdef' for c in lut_sha), 'Native LUT binding is absent.')
        rectified[ident] = entry
    require(set(rectified) == registered_ids, 'Rectification does not cover every registered photograph exactly once.')
    context.update(images=rectified, manifestSHA256=digest(rect_file))
    return context


def native_lut_context(dataset, provenance, report, frames, native):
    require(provenance.get('requiresNativeLUTProjection') is True and provenance.get('nativeGaussianCompatible') is False and
            provenance.get('projectionKind') == 'AppleNativeRadialLUT', 'Native-LUT input must declare its nonlinear projection explicitly.')
    require(not provenance.get('rectificationManifest'), 'Native-LUT JPEG mode cannot silently consume rectified images.')
    context = originals_context(dataset, provenance, report, frames)
    path = safe_file(dataset, provenance['nativeLUTManifest']); document = json.loads(path.read_text())
    require(document.get('schemaVersion') == 1 and document.get('projection') == 'AppleNativeRadialLUT' and
            document.get('formula') == 'source=c+(pinhole-c)*(1+linearLUT(radius))', 'Unsupported native-LUT projection or direction.')
    cameras = {c['frameID']: c for c in native['cameras']}
    require(len(cameras) == len(native['cameras']), 'Duplicate native calibration frame IDs.')
    rows = {}
    for row in document['images']:
        ident = row['frameID']; require(ident in context['registeredIDs'] and ident not in rows and ident in cameras, 'Missing or duplicate native-LUT frame binding.')
        camera = cameras[ident]; lens = camera.get('lensDistortion')
        require(lens is not None, 'Explicit native-LUT row has no native lens payload.')
        require(row['sourceFile'] == context['originals'][ident]['sourceFile'] and row['sourceSHA256'] == context['originals'][ident]['sourceSHA256'], 'Native LUT lost its original-photo binding.')
        require(row['center'] == lens['center'] and row['radialLookupTable'] == lens['radialLookupTable'] and row['intrinsicsColumnMajor'] == camera['intrinsicsColumnMajor'],
                'Native LUT/K differs from the original Apple calibration.')
        expected_sha = hashlib.sha256(json.dumps(lens,sort_keys=True,separators=(',', ':'),allow_nan=False).encode()).hexdigest()
        require(row['lutSHA256'] == expected_sha, 'Native lens payload SHA mismatch.')
        center = row['center']; table = row['radialLookupTable']; width = row['width']; height = row['height']
        require(len(center) == 2 and len(table) >= 2 and width > 0 and height > 0, 'Invalid native lens dimensions/table.')
        finite(center + table, 'native lens payload')
        require(0 <= center[0] <= width-1 and 0 <= center[1] <= height-1 and all(v > -1 for v in table), 'Native radial map is not physically representable.')
        radius = math.hypot(max(center[0],width-center[0]),max(center[1],height-center[1]))
        require(math.isfinite(row['radiusMax']) and abs(row['radiusMax']-radius) <= 1e-9*max(1,radius), 'Native Apple maximum-radius formula mismatch.')
        rows[ident] = row
    require(set(rows) == context['registeredIDs'], 'Native LUT rows do not cover every registered frame exactly once.')
    if provenance.get('nativeCalibration'):
        copy = safe_file(dataset, provenance['nativeCalibration'])
        require(digest(copy) == provenance['inputSHA256'].get(provenance['calibration']), 'Archived native camera calibration changed.')
    context.update(images=rows, manifestSHA256=digest(path))
    return context


def write_native_lut(path, row):
    text = 'FORMA_RADIAL_LUT_V1\n'
    text += f"{row['width']} {row['height']} " + ' '.join(format(v,'.17g') for v in [*row['center'],row['radiusMax']]) + f" {len(row['radialLookupTable'])}\n"
    text += '\n'.join(format(v,'.17g') for v in row['radialLookupTable']) + '\n'
    path.write_text(text)


def cam_intrinsics(k):
    aspect = k['fy'] / k['fx']
    focal = k['fx'] / k['width'] if k['width'] / k['height'] * aspect >= 1 else k['fy'] / k['height']
    # texrecon TextureView subtracts0.5 after K*E*X. Preserve integer-centered COLMAP pixels.
    return focal, 0.0, 0.0, aspect, (k['cx'] + 0.5) / k['width'], (k['cy'] + 0.5) / k['height']


def cam_pixel(k, cam, xyz_camera):
    focal, _, _, aspect, px, py = cam
    if k['width'] / k['height'] * aspect < 1:
        ax = focal * k['height'] / aspect; ay = focal * k['height']
    else:
        ax = focal * k['width']; ay = focal * k['width'] * aspect
    x, y, z = xyz_camera
    return ax*x/z + k['width']*px - 0.5, ay*y/z + k['height']*py - 0.5


def clone_or_copy(source, destination):
    cloned = False
    if sys.platform == 'darwin':
        libc = ctypes.CDLL(None, use_errno=True)
        libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        libc.clonefile.restype = ctypes.c_int
        cloned = libc.clonefile(os.fsencode(source), os.fsencode(destination), 0) == 0
    if not cloned:
        if destination.exists(): destination.unlink()
        shutil.copyfile(source, destination)
    a, b = source.stat(), destination.stat()
    require((a.st_dev, a.st_ino) != (b.st_dev, b.st_ino), 'Hard-linked photo copy rejected.')
    return 'APFS clone' if cloned else 'byte copy'


def compare_manifest(frame, k, image):
    require((frame['imageWidth'], frame['imageHeight']) == (k['width'], k['height']), 'Manifest/COLMAP raster mismatch.')
    values = frame['intrinsics']; require(len(values) == 9, 'Manifest K is not3x3.'); finite(values, 'manifest K')
    expected = [k['fx'],0,0,0,k['fy'],0,k['cx'],k['cy'],1]
    require(max(abs(a-b) for a,b in zip(values,expected)) < 1e-6, 'COLMAP K differs from the accepted manifest, or contains skew.')
    pose = frame['cameraToWorld']; require(len(pose) == 16, 'Manifest pose is not4x4.'); finite(pose, 'manifest pose')
    require(max(abs(pose[i]-v) for i,v in zip((3,7,11,15),(0,0,0,1))) < 1e-6, 'Manifest pose is not affine.')
    # Manifest is C2W OpenGL. Derive W2C CV independently from its rigid transform.
    rgl = [[pose[c*4+r] for c in range(3)] for r in range(3)]; center = pose[12:15]
    expected_r = [[(1 if row == 0 else -1)*rgl[column][row] for column in range(3)] for row in range(3)]
    expected_t = [-v for v in mv(expected_r, center)]
    require(max(abs(expected_r[r][c]-image['R'][r][c]) for r in range(3) for c in range(3)) < 1e-5 and max(abs(a-b) for a,b in zip(expected_t,image['t'])) < 1e-5,
            'COLMAP extrinsics differ from the accepted manifest camera.')


def prepare(dataset, validation_report, output, native_lut_scene=False):
    started = time.perf_counter(); dataset = dataset.resolve(); validation_report = validation_report.resolve()
    require(not output.exists() and not output.is_symlink(), 'Output must be a new directory.')
    report = json.loads(validation_report.read_text())
    require(report.get('decision', {}).get('accepted') is True and report.get('inputProblems') == [] and report.get('inputsUnchanged') is True,
            'Photogrammetry calibration has not passed its native projection validation.')
    require(report.get('exportedDataset') and Path(report['exportedDataset']).resolve() == dataset and
            (report.get('exportedAllSourceFrames') is True or report.get('exportedAllRegisteredFrames') is True),
            'Validation report does not publish this complete registered dataset.')
    files = {name: safe_file(dataset, name) for name in ('cameras.txt','images.txt','dataset.json','calibration-provenance.json')}
    hashes_before = {name: digest(path) for name,path in files.items()}
    provenance = json.loads(files['calibration-provenance.json'].read_text())
    require(provenance.get('decision') == report['decision'] and provenance.get('inputSHA256') == report.get('inputSHA256'), 'Calibration provenance/report disagreement.')
    require(provenance.get('decision', {}).get('accepted') is True, 'Unaccepted dataset provenance.')
    calibration_file = Path(provenance['calibration'])
    require(calibration_file.is_file() and not calibration_file.is_symlink(), 'Native camera calibration is unavailable.')
    require(digest(calibration_file) == provenance['inputSHA256'].get(str(calibration_file)), 'Native camera calibration changed after validation.')
    manifest = json.loads(files['dataset.json'].read_text()); frames = manifest['frames']
    native = json.loads(calibration_file.read_text())
    rectified = None; native_lut = None
    if provenance.get('requiresNativeLUTProjection'):
        require(native_lut_scene, 'This dataset requires nonlinear native LUT projection; explicitly select --native-lut-scene.')
        require(report.get('exportedAllRegisteredFrames') is True and report.get('exportedAllNativePoints') is True, 'Native-LUT dataset is missing registered-frame/native-point publication evidence.')
        native_lut = native_lut_context(dataset, provenance, report, frames, native)
    elif provenance.get('rectificationManifest'):
        require(not native_lut_scene, 'Native-LUT JPEG mode cannot consume a rectified-image dataset.')
        require(report.get('exportedAllRegisteredFrames') is True and report.get('exportedAllNativePoints') is True, 'Rectified dataset is missing registered-frame/native-point publication evidence.')
        rectified = rectification_context(dataset, provenance, report, frames)
    else:
        require(not native_lut_scene, 'Dataset does not publish native-LUT projection evidence.')
        require(report.get('exportedAllSourceFrames') is True, 'Missing original-image completeness evidence.')
        require(all(c.get('lensDistortion') is None for c in native['cameras']), 'Native lens LUT is present without a validated rectification publication.')
    cameras = load_cameras(files['cameras.txt']); images = load_images(files['images.txt'])
    frames_by_name = {}
    for frame in frames:
        rel = safe_relative(frame['rgbFile']); require(rel.parts[0] == 'images', 'Source frame is not within images/.')
        name = '/'.join(rel.parts[1:]); require(name and name not in frames_by_name, 'Duplicate calibrated photo identity.')
        frames_by_name[name] = frame
    require(len(images) == len(frames) and {i['name'] for i in images} == set(frames_by_name), 'COLMAP images do not cover every accepted frame exactly once.')
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.texrecon-scene-', dir=output.parent))
    rows = []; reprojection_max = 0.0
    try:
        for number, image in enumerate(images):
            require(image['cameraID'] in cameras, 'Missing camera referenced by a photograph.')
            k = cameras[image['cameraID']]; frame = frames_by_name[image['name']]
            compare_manifest(frame, k, image)
            source = safe_file(dataset, frame['rgbFile'])
            require(image_dimensions(source) == (k['width'], k['height']), 'Native image dimensions differ from calibrated K; no K scaling guessed.')
            before = digest(source)
            derivation = None
            if native_lut:
                row = native_lut['images'][frame['id']]
                require(source.suffix.lower() in ('.jpg', '.jpeg') and row['imageFile'] == frame['rgbFile'] and row['sourceSHA256'] == before,
                        'Native-LUT JPEG bytes/path differ from their validated original.')
                require((row['width'],row['height']) == (k['width'],k['height']) and row['intrinsicsColumnMajor'] == frame['intrinsics'], 'Native LUT dimensions/K differ from the prepared camera.')
            elif rectified:
                derivation = rectified['images'][frame['id']]
                require(source.suffix.lower() == '.png' and derivation['rectifiedFile'] == frame['rgbFile'] and derivation['rectifiedSHA256'] == before,
                        'Rectified PNG bytes/path do not match their validated derivation.')
                require((derivation['width'], derivation['height']) == (k['width'], k['height']), 'Rectification changed the native raster dimensions.')
                finite(derivation['nativeIntrinsicsColumnMajor'], 'rectification intrinsics')
                require(len(derivation['nativeIntrinsicsColumnMajor']) == 9 and max(abs(a-b) for a,b in zip(derivation['nativeIntrinsicsColumnMajor'],frame['intrinsics'])) < 1e-6,
                        'Rectified PNG intrinsics do not match the accepted calibrated camera.')
            else:
                require(source.suffix.lower() in ('.jpg', '.jpeg'), 'PNG needs explicit validated rectification provenance.')
                original = str(Path(provenance['sourceDataset']) / frame['rgbFile'])
                require(provenance['inputSHA256'].get(original) == before, 'Photo bytes differ from the accepted native calibration sources.')
            stem = f'{number:08d}'; target = stage / (stem + ('.png' if rectified else '.jpg')); copied = clone_or_copy(source, target)
            require(digest(target) == before and digest(source) == before, 'Photo changed while copying.')
            cam = cam_intrinsics(k)
            finite(cam, 'normalized CAM intrinsics')
            extrinsics = image['t'] + [v for row in image['R'] for v in row]
            text = ' '.join(format(v,'.17g') for v in extrinsics) + '\n' + ' '.join(format(v,'.17g') for v in cam) + '\n'
            camera_output = stage / (stem + '.cam'); camera_output.write_text(text)
            lut_receipt = None
            if native_lut:
                sidecar = stage / (stem + '.forma-lut')
                lens_row = native_lut['images'][frame['id']]
                write_native_lut(sidecar, lens_row)
                lut_receipt = dict(sidecar=sidecar.name,sidecarSHA256=digest(sidecar),nativePayloadSHA256=lens_row['lutSHA256'],
                                   center=lens_row['center'],radiusMax=lens_row['radiusMax'],count=len(lens_row['radialLookupTable']),
                                   formula='sourcePixel=center+(pinholePixel-center)*(1+interpLUT(radius/rMax)); native zero-centered pixel coordinates')
            error = 0.0
            # The same physical camera points, transformed into world then back through serialized E.
            for pc in ((0.0,0.0,1.0),(.37,-.23,2.4),(-.31,.44,3.7)):
                world = mv(list(map(list,zip(*image['R']))), [pc[c]-image['t'][c] for c in range(3)])
                reconstructed = [a+b for a,b in zip(mv(image['R'],world),image['t'])]
                projected = cam_pixel(k, cam, reconstructed)
                reference = (k['fx']*pc[0]/pc[2]+k['cx'], k['fy']*pc[1]/pc[2]+k['cy'])
                error = max(error, *(abs(a-b) for a,b in zip(projected,reference)))
            require(error < 1e-6, 'CAM conversion does not preserve native calibrated image coordinates.')
            reprojection_max = max(reprojection_max,error)
            rows.append(dict(frameID=frame['id'],imageID=image['imageID'],sourceRelativePath=frame['rgbFile'],photo=target.name,
                camera=camera_output.name,bytes=source.stat().st_size,photoSHA256=before,cameraSHA256=digest(camera_output),copyMethod=copied,
                nativeWidth=k['width'],nativeHeight=k['height'],intrinsics=k,worldToCameraRotationRows=image['R'],worldToCameraTranslation=image['t'],
                camIntrinsics=list(cam),nativePixelConversionMaxError=error,rectification=derivation,nativeLUT=lut_receipt))
        hashes_after = {name:digest(path) for name,path in files.items()}
        require(hashes_before == hashes_after, 'Calibrated input metadata changed before publication.')
        result = dict(schemaVersion=1,sourceDataset=str(dataset),validationReport=str(validation_report),validationReportSHA256=digest(validation_report),
            nativeCalibrationSHA256=digest(calibration_file),inputMetadataSHA256=hashes_before,photoCount=len(rows),photoBytes=sum(r['bytes'] for r in rows),
            files=rows,allAcceptedPhotographsCopied=True,allRegisteredPhotographsCopied=True,photoRasterResized=False,
            photoBytesChangedByThisAdapter=False,hardLinksUsed=False,
            pixelConvention='CAM principal=(COLMAP principal+0.5)/dimension; texrecon subtracts0.5 after projection; integer-centered native pixels preserved.',
            maximumNativePixelConversionError=reprojection_max,geometryIncluded=False,texreconExecuted=False,GPUUsed=False,
            coordinateSystem=provenance.get('units','Photogrammetry estimated CRS; metric scale unvalidated'),seconds=time.perf_counter()-started)
        if rectified:
            result.update(originalSourceFrameCount=rectified['originalCount'],registeredFrameCount=rectified['registeredCount'],
                          unregisteredFrameCount=len(rectified['unregistered']),unregisteredOriginals=rectified['unregistered'],
                          rectificationManifestSHA256=rectified['manifestSHA256'],sourceOriginalsRegistrySHA256=rectified['registrySHA256'],
                          photoDerivation='Byte-identical copies of validated native-size rectified PNG; every original JPEG remains archived in calibrated dataset.')
        if native_lut:
            result.update(originalSourceFrameCount=native_lut['originalCount'],registeredFrameCount=native_lut['registeredCount'],
                          unregisteredFrameCount=len(native_lut['unregistered']),unregisteredOriginals=native_lut['unregistered'],
                          nativeLUTManifestSHA256=native_lut['manifestSHA256'],sourceOriginalsRegistrySHA256=native_lut['registrySHA256'],
                          projectionKind='AppleNativeRadialLUT',requiresNativeLUTProjection=True,nativeGaussianCompatible=False,
                          requiredTexreconCapability='FORMA_RADIAL_LUT_V1',nativeLUTSidecarCount=len(native_lut['images']),
                          photoDerivation='Native JPEG byte-exact copies; no rectification, cropping, resizing or reencoding. Nonlinear projection is carried by mandatory per-camera sidecars.')
        dump(stage/'prepare-report.json',result)
        stage.rename(output)
        print(json.dumps(dict(output=str(output.resolve()),photoCount=len(rows),photoBytes=result['photoBytes'],maximumNativePixelConversionError=reprojection_max,texreconExecuted=False),indent=2))
        return result
    finally:
        if stage.exists(): shutil.rmtree(stage)


def self_test():
    # Pillow is used only to author two tiny, real JPEG fixtures. The actual adapter is stdlib-only.
    from PIL import Image
    with tempfile.TemporaryDirectory(prefix='forma-texrecon-adapter-') as temp:
        base = Path(temp); dataset = base/'validated'; (dataset/'images').mkdir(parents=True)
        frames = []; native = []; camera_lines = []; image_lines = []; photo_hashes = {}
        definitions = [(32,24,25.3,28.7,12.2,10.3,[1,0,0,0],[.13,-.27,.49]),
                       (24,32,31.2,27.1,10.4,18.6,[0,0,1,0],[-.31,.47,-.58])]
        for i,(w,h,fx,fy,cx,cy,q,t) in enumerate(definitions,1):
            name = f'images/source{i}.jpg'; image = Image.new('RGB',(w,h)); image.putdata([(x*7%256,y*9%256,(x+y)*5%256) for y in range(h) for x in range(w)]);image.save(dataset/name,quality=95)
            r = quaternion_rotation(q); center = [-v for v in mv(list(map(list,zip(*r))),t)]
            rgl = [[r[c][row]*(1 if c == 0 else -1) for c in range(3)] for row in range(3)]
            pose = [rgl[row][col] if row < 3 and col < 3 else (center[row] if col == 3 and row < 3 else (1 if col == row == 3 else 0)) for col in range(4) for row in range(4)]
            frames.append(dict(id=f'fixture{i}',rgbFile=name,imageWidth=w,imageHeight=h,intrinsics=[fx,0,0,0,fy,0,cx,cy,1],cameraToWorld=pose))
            native.append(dict(frameID=f'fixture{i}',lensDistortion=None));photo_hashes[str(dataset/name)] = digest(dataset/name)
            camera_lines.append(f'{i} PINHOLE {w} {h} {fx} {fy} {cx} {cy}')
            image_lines.append(f'{i} '+' '.join(map(str,[*q,*t]))+f' {i} source{i}.jpg\n')
        dump(dataset/'dataset.json',dict(frames=frames)); (dataset/'cameras.txt').write_text('\n'.join(camera_lines)+'\n'); (dataset/'images.txt').write_text('\n'.join(image_lines)+'\n')
        calibration = base/'native-cameras.json';dump(calibration,dict(cameras=native));hashes={**photo_hashes,str(calibration):digest(calibration)}
        decision=dict(accepted=True,selectedConvention='authored CPU fixture')
        provenance=dict(calibration=str(calibration),sourceDataset=str(dataset),inputSHA256=hashes,decision=decision,units='synthetic fixture coordinates')
        dump(dataset/'calibration-provenance.json',provenance)
        report=base/'validation.json';dump(report,dict(decision=decision,inputProblems=[],inputsUnchanged=True,exportedDataset=str(dataset),exportedAllSourceFrames=True,inputSHA256=hashes))
        result=prepare(dataset,report,base/'scene')
        require(result['photoCount']==2 and result['maximumNativePixelConversionError']<1e-10,'Authored camera conversion failed.')
        for row in result['files']:
            require(digest(base/'scene'/row['photo'])==photo_hashes[str(dataset/row['sourceRelativePath'])],'Fixture source changed.')
        try:
            prepare(dataset,report,base/'scene')
            raise AssertionError('Existing output was overwritten.')
        except ValueError: pass
        rejected=json.loads(report.read_text());rejected['decision']=dict(accepted=False);dump(base/'rejected.json',rejected)
        try:
            prepare(dataset,base/'rejected.json',base/'must-not-exist')
            raise AssertionError('Rejected calibration was accepted.')
        except ValueError: pass
        require(not (base/'must-not-exist').exists(),'Rejected calibration published an output.')
    print('PASS: two real JPEGs, landscape/portrait anisotropic K, noncentral principal, translated identity/180degree cameras, exact native pixel projection and winding-independent E, all-photo copies/hash/no hardlink, existing-output and unaccepted-calibration rejection; no texrecon/GPU.')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset',type=Path);parser.add_argument('--validation-report',type=Path);parser.add_argument('--output',type=Path)
    parser.add_argument('--native-lut-scene',action='store_true',help='Require validated Apple native nonlinear projection and emit JPEG+CAM+.forma-lut, with no image resampling.')
    parser.add_argument('--self-test',action='store_true');args=parser.parse_args()
    if args.self_test: self_test();return
    require(args.dataset and args.validation_report and args.output,'--dataset, --validation-report and --output are required.')
    prepare(args.dataset,args.validation_report,args.output,native_lut_scene=args.native_lut_scene)


if __name__ == '__main__': main()
