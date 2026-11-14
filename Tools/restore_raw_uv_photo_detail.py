"""Photographic detail recovery on an existing Raw UV raster.

Experimental, local, no generative model and no mesh/UV/model-library writes.
Confidence combines source support, registration, structural agreement and
measured detail; source color/low frequencies never replace the Raw base.
"""
import os
os.environ['OPENCV_OPENCL_RUNTIME'] = 'disabled'
import argparse, hashlib, json, time, struct, zlib, shutil
from pathlib import Path
import cv2
import numpy as np


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1048576), b''):
            h.update(block)
    return h.hexdigest()


def mark_srgb_png(path):
    # OpenCV does not emit an sRGB chunk. Preserve the explicit interpretation
    # used by the photographic capture and Raw atlas without recompressing IDAT.
    temporary = path.with_name(path.name + '.srgb')
    with path.open('rb') as source, temporary.open('xb') as output:
        header = source.read(33)
        require(header[:8] == b'\x89PNG\r\n\x1a\n' and header[12:16] == b'IHDR', 'Invalid encoded PNG.')
        output.write(header)
        kind, value = b'sRGB', b'\0'
        output.write(struct.pack('>I', 1) + kind + value + struct.pack('>I', zlib.crc32(kind + value) & 0xffffffff))
        shutil.copyfileobj(source, output, length=1048576)
    temporary.replace(path)


def blur(value, sigma):
    return cv2.GaussianBlur(value, (0, 0), sigma, borderType=cv2.BORDER_REFLECT_101)


def linear(rgb):
    value = rgb.astype(np.float32) / 255
    return np.where(value <= .04045, value / 12.92, ((value + .055) / 1.055) ** 2.4)


def encode(rgb):
    value = np.clip(rgb, 0, 1)
    value = np.where(value <= .0031308, value * 12.92, 1.055 * value ** (1 / 2.4) - .055)
    return np.clip(np.rint(value * 255), 0, 255).astype(np.uint8)


def luminance(rgb):
    return rgb[:, :, 0] * .2126 + rgb[:, :, 1] * .7152 + rgb[:, :, 2] * .0722


def band(log_y, sigma):
    return blur(log_y, .6) - blur(log_y, sigma)


def registration_image(log_y):
    # Remove slowly varying exposure before registration. The image used here
    # only estimates correspondence; it never becomes an output texture.
    centered = blur(log_y, .6) - blur(log_y, 12)
    return np.rint(np.clip(centered * 48 + 128, 0, 255)).astype(np.uint8)


def remap_rows(image, flow):
    # All native pixels are processed. Row blocks bound temporary coordinate
    # storage without resizing the raster or limiting the amount of data.
    height, width = flow.shape[:2]
    result = np.empty_like(image)
    columns = np.arange(width, dtype=np.float32)[None, :]
    for first in range(0, height, 128):
        end = min(height, first + 128)
        x = columns + flow[first:end, :, 0]
        y = np.arange(first, end, dtype=np.float32)[:, None] + flow[first:end, :, 1]
        result[first:end] = cv2.remap(image, x, y, cv2.INTER_LINEAR,
                                     borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    return result


def recover(raw, photo, valid, *, sigma=4., register=True):
    require(raw.dtype == np.uint8 and photo.dtype == np.uint8 and raw.shape == photo.shape,
            'Native RGB rasters must match exactly in dimensions and encoding.')
    require(raw.ndim == 3 and raw.shape[2] == 3 and valid.shape == raw.shape[:2], 'Invalid UV raster or support mask.')
    require(sigma > .6, 'The photographic detail band must be wider than the noise-exclusion band.')
    raw_linear = linear(raw)
    raw_y = luminance(raw_linear)
    raw_log = np.log(raw_y + 1e-5)
    prepared = photo.copy()
    prepared[~valid] = raw[~valid]
    photo_log = np.log(luminance(linear(prepared)) + 1e-5)
    height, width = valid.shape
    if register:
        forward = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
        reverse = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
        forward.setFinestScale(0); reverse.setFinestScale(0)
        base_registration = registration_image(raw_log)
        photo_registration = registration_image(photo_log)
        flow = forward.calc(base_registration, photo_registration, None)
        back = reverse.calc(photo_registration, base_registration, None)
        closure = np.linalg.norm(flow + remap_rows(back, flow), axis=2)
        photo_log = remap_rows(photo_log, flow)
        support = remap_rows(valid.astype(np.uint8) * 255, flow) == 255
        displacement = np.linalg.norm(flow, axis=2)
        registration_confidence = np.exp(-.5 * closure ** 2) * np.exp(-.5 * (displacement / 8) ** 2)
        # Explicit in-bounds test, since reverse flow zero outside the image is
        # not evidence of a valid forward/backward registration.
        for first in range(0, height, 128):
            end = min(height, first + 128)
            x = np.arange(width, dtype=np.float32)[None, :] + flow[first:end, :, 0]
            y = np.arange(first, end, dtype=np.float32)[:, None] + flow[first:end, :, 1]
            support[first:end] &= (x >= 0) & (x <= width - 1) & (y >= 0) & (y <= height - 1)
        registration_report = dict(enabled=True, medianFlowPixels=float(np.median(displacement[valid])) if valid.any() else None,
            p95FlowPixels=float(np.percentile(displacement[valid], 95)) if valid.any() else None,
            medianForwardBackwardErrorPixels=float(np.median(closure[valid])) if valid.any() else None)
        del forward, reverse, flow, back, closure, displacement, base_registration, photo_registration
    else:
        support = valid.copy()
        registration_confidence = np.ones(valid.shape, np.float32)
        registration_report = dict(enabled=False)
    # Reapply the Raw signal outside support before filtering. Empty atlas space
    # and observations discarded by registration must not create fake edges.
    support &= valid
    photo_log[~support] = raw_log[~support]
    raw_band = band(raw_log, sigma)
    photo_band = band(photo_log, sigma)
    raw_mean = blur(raw_band, 6)
    photo_mean = blur(photo_band, 6)
    raw_power = np.maximum(blur(raw_band * raw_band, 6) - raw_mean * raw_mean, 0)
    photo_power = np.maximum(blur(photo_band * photo_band, 6) - photo_mean * photo_mean, 0)
    covariance = blur(raw_band * photo_band, 6) - raw_mean * photo_mean
    correlation = np.clip(covariance / np.sqrt(raw_power * photo_power + 1e-12), 0, 1)
    # A blurred observation and flat/noisy support cannot be promoted simply
    # because they are present. These are confidence weights, not data quotas.
    sharper = np.clip((np.sqrt(photo_power / (raw_power + 1e-12)) - 1) / .12, 0, 1)
    signal = raw_power / (raw_power + .000025)
    color_agreement = np.exp(-.5 * ((blur(photo_log, 12) - blur(raw_log, 12)) / .5) ** 2)
    distance = cv2.distanceTransform(support.astype(np.uint8), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    phase = np.clip((distance - 1) / 12, 0, 1)
    boundary = phase * phase * (3 - 2 * phase)
    confidence = boundary * registration_confidence * correlation ** 2 * sharper * signal * color_agreement
    confidence = np.minimum(confidence, blur(confidence, 2))
    confidence[~support] = 0
    target_delta = confidence * (photo_band - raw_band)
    new_y = np.maximum(np.exp(raw_log + target_delta) - 1e-5, 0)
    scale = np.divide(new_y, raw_y, out=np.ones_like(new_y), where=raw_y > 1e-10)
    candidate = raw_linear * scale[:, :, None]
    out_of_gamut = np.any((candidate < 0) | (candidate > 1), axis=2)
    confidence[out_of_gamut] = 0
    candidate[out_of_gamut] = raw_linear[out_of_gamut]
    result = encode(candidate)
    result[confidence == 0] = raw[confidence == 0]
    changed = np.any(result != raw, axis=2)
    require(not changed[~valid].any(), 'Pixels outside valid photo support changed.')
    boundary_pixels = valid & (cv2.erode(valid.astype(np.uint8), np.ones((3, 3), np.uint8)) == 0)
    require(not changed[boundary_pixels].any(), 'The external UV/support boundary changed.')
    actual_delta = np.log(luminance(linear(result)) + 1e-5) - raw_log
    low_drift = blur(actual_delta, 12)
    report = dict(nativeDimensions=[width, height], sigmaBandPixels=[.6, sigma], registration=registration_report,
        validPhotoPixels=int(valid.sum()), acceptedSupportPixels=int(support.sum()), changedPixels=int(changed.sum()),
        outsideSupportChangedPixels=int(changed[~valid].sum()), externalSupportBoundaryChangedPixels=int(changed[boundary_pixels].sum()),
        candidateOutOfGamutPixelsRejected=int(out_of_gamut.sum()),
        meanConfidence=float(confidence[valid].mean()) if valid.any() else 0,
        lowFrequencySigma12RMSLogLuma=float(np.sqrt(np.mean(low_drift[valid] ** 2))) if valid.any() else 0,
        photoSignal='Only registered, measured photographic band replaces the same Raw luminance band; no generated detail or amplitude boost.',
        color='Raw linear chromaticity is retained before sRGB8 rounding. Raw low-frequency structure is the base; measured drift includes finite masks/rounding.',
        limitations=['Local optical flow estimates image registration, not geometric accuracy.',
                     'Confidence can reject poor observations; a full-raster result does not by itself prove visual improvement.'])
    return result, confidence, report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--raw', required=True, type=Path)
    parser.add_argument('--photo', required=True, type=Path, help='Photo reprojected onto exactly the same native Raw UV grid; alpha is valid support.')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--sigma', type=float, default=4)
    parser.add_argument('--no-registration', action='store_true')
    args = parser.parse_args()
    require(not args.output.exists(), 'Fresh output required; earlier results are preserved.')
    args.output.mkdir(parents=True)
    cv2.ocl.setUseOpenCL(False)
    cv2.setNumThreads(os.cpu_count() or 1)
    hashes = {str(p): digest(p) for p in [args.raw, args.photo]}
    raw = cv2.imread(str(args.raw), cv2.IMREAD_UNCHANGED)
    photo = cv2.imread(str(args.photo), cv2.IMREAD_UNCHANGED)
    require(raw is not None and photo is not None and photo.ndim == 3 and photo.shape[2] == 4, 'Raw RGB(A) and photographic RGBA PNGs are required.')
    require(raw.shape[:2] == photo.shape[:2], 'No resizing allowed: Raw and reprojected photo dimensions differ.')
    raw_rgb = cv2.cvtColor(raw[:, :, :3], cv2.COLOR_BGR2RGB)
    photo_rgb = cv2.cvtColor(photo[:, :, :3], cv2.COLOR_BGR2RGB)
    started = time.perf_counter()
    result, confidence, report = recover(raw_rgb, photo_rgb, photo[:, :, 3] == 255,
                                         sigma=args.sigma, register=not args.no_registration)
    result_bgr = cv2.cvtColor(result, cv2.COLOR_RGB2BGR)
    if raw.shape[2] == 4:
        result_bgr = np.dstack((result_bgr, raw[:, :, 3]))
    require(cv2.imwrite(str(args.output/'texture.png'), result_bgr), 'PNG encoding failed.')
    mark_srgb_png(args.output/'texture.png')
    require(cv2.imwrite(str(args.output/'confidence.png'), np.rint(confidence * 255).astype(np.uint8)), 'Confidence PNG encoding failed.')
    report.update(seconds=time.perf_counter() - started, inputsSHA256=hashes, qualityAccepted=False)
    for name, sha in hashes.items():
        require(digest(Path(name)) == sha, 'An original input changed during processing.')
    (args.output/'report.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    print(json.dumps({k: report[k] for k in ['nativeDimensions', 'changedPixels', 'meanConfidence', 'lowFrequencySigma12RMSLogLuma', 'seconds']}), flush=True)


if __name__ == '__main__':
    main()
