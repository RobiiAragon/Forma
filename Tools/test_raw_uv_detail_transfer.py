"""Small, read-only atlas-ROI experiment using real aligned photographic detail.

No generic sharpening, learned/generated detail, UV edits or model publication.
All output pixels remain on the existing native 287x300 atlas grid.
"""
import argparse
import hashlib
import json
from pathlib import Path
import cv2
import numpy as np


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def linear(rgb):
    s = rgb.astype(np.float64) / 255
    return np.where(s <= .04045, s / 12.92, ((s + .055) / 1.055) ** 2.4)


def encode(rgb):
    s = np.clip(rgb, 0, 1)
    result = np.where(s <= .0031308, s * 12.92, 1.055 * s ** (1 / 2.4) - .055)
    return np.clip(np.rint(result * 255), 0, 255).astype(np.uint8)


def blur(image, sigma):
    return cv2.GaussianBlur(image, (0, 0), sigma, borderType=cv2.BORDER_REFLECT_101)


def luma(rgb):
    return rgb @ np.asarray([.2126, .7152, .0722])


def log_luma(rgb):
    return np.log(luma(rgb) + 1e-5)


def lab_from_linear_rgb(rgb):
    # Continuous double-precision D65/sRGB colorimetry. Do not quantize a blurred
    # image back to8bit before measuring small low-frequency color differences.
    xyz = rgb @ np.asarray([[.4124564,.2126729,.0193339],
                            [.3575761,.7151522,.1191920],
                            [.1804375,.0721750,.9503041]])
    xyz /= np.asarray([.95047,1.,1.08883])
    delta = 6/29
    f = np.where(xyz > delta**3, np.cbrt(xyz), xyz/(3*delta**2)+4/29)
    return np.stack([116*f[:,:,1]-16,500*(f[:,:,0]-f[:,:,1]),200*(f[:,:,1]-f[:,:,2])],axis=2)


def band(log_y, sigma):
    # Exclude the finest subpixel/noise band rather than sharpening it. The
    # transferred signal is the actual photo's sigma0.6-to-sigmaN residual.
    return blur(log_y, .6) - blur(log_y, sigma)


def stats(values):
    if values.size == 0:
        return dict(count=0, mean=None, rms=None, p50Abs=None, p95Abs=None, maxAbs=None)
    return dict(count=int(values.size), mean=float(values.mean()), rms=float(np.sqrt(np.mean(values**2))),
                p50Abs=float(np.percentile(np.abs(values), 50)),
                p95Abs=float(np.percentile(np.abs(values), 95)), maxAbs=float(np.max(np.abs(values))))


def correlation(left, right):
    if left.size < 2 or left.std() == 0 or right.std() == 0:
        return None
    return float(np.corrcoef(left, right)[0, 1])


def save_rgb(path, rgb):
    if not cv2.imwrite(str(path), cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)):
        raise RuntimeError('Could not save experimental PNG')


def panel(images, destination):
    result = []
    for name, rgb in images:
        canvas = np.full((rgb.shape[0]+38, rgb.shape[1], 3), 24, np.uint8)
        canvas[38:] = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
        cv2.putText(canvas, name, (6, 25), cv2.FONT_HERSHEY_SIMPLEX, .48, (255,255,255), 1, cv2.LINE_AA)
        result.append(canvas)
    if not cv2.imwrite(str(destination), np.concatenate(result, axis=1)):
        raise RuntimeError('Could not save native comparison panel')


def diagnostics(raw, after, photo, delta_target, alpha, mask, distance, sigma):
    raw_linear, after_linear = linear(raw), linear(after)
    raw_log, after_log = log_luma(raw_linear), log_luma(after_linear)
    actual_delta = after_log-raw_log
    interior = alpha > .999
    transition = mask & (distance <= 14)
    delta_smooth = blur(actual_delta, 4)
    dx = cv2.Sobel(delta_smooth, cv2.CV_64F, 1, 0, ksize=3)/8
    dy = cv2.Sobel(delta_smooth, cv2.CV_64F, 0, 1, ksize=3)/8
    raw_low, after_low = blur(raw_linear, 12), blur(after_linear, 12)
    # Lab is measured only after identically filtering both in linear RGB.
    # This is a local color-drift diagnostic, not perceptual ground truth.
    raw_lab = lab_from_linear_rgb(raw_low)
    after_lab = lab_from_linear_rgb(after_low)
    lab_delta = after_lab-raw_lab
    raw_chroma = raw_linear/np.maximum(raw_linear.sum(axis=2, keepdims=True), 1e-12)
    after_chroma = after_linear/np.maximum(after_linear.sum(axis=2, keepdims=True), 1e-12)
    source_band = band(log_luma(linear(photo)), sigma)
    raw_band, after_band = band(raw_log, sigma), band(after_log, sigma)
    boundary4 = mask & (cv2.erode(mask.astype(np.uint8),cv2.getStructuringElement(cv2.MORPH_CROSS,(3,3))) == 0)
    return dict(outsideMaskChangedRGBPixels=int(np.count_nonzero(np.any(after[~mask] != raw[~mask], axis=1))),
        fourConnectedMaskBoundaryChangedRGBPixels=int(np.count_nonzero(np.any(after[boundary4] != raw[boundary4],axis=1))),
        fullyUnmodifiedAlphaZeroPixels=int(np.count_nonzero(np.all(after[alpha == 0] == raw[alpha == 0], axis=1))),
        changedInsideRGBPixels=int(np.count_nonzero(np.any(after[mask] != raw[mask], axis=1))),
        encodedDeltaLogLuma=stats(actual_delta[mask]),
        lowFrequencyLogLumaDrift={str(s): stats((blur(after_log, s)-blur(raw_log, s))[mask]) for s in [4,12]},
        lowFrequencyLinearRGBDriftSigma12=stats((after_low-raw_low)[mask]),
        lowFrequencyDeltaE76Sigma12=stats(np.linalg.norm(lab_delta[mask], axis=1)),
        lowFrequencyChromaABDriftSigma12=stats(np.linalg.norm(lab_delta[mask,1:], axis=1)),
        encodedLinearChromaticityDrift=stats((after_chroma-raw_chroma)[mask]),
        transitionBandSmoothedAddedGradientLogLuma=stats(np.hypot(dx,dy)[transition]),
        actualDeltaVsPhotographicDeltaCorrelation=correlation(actual_delta[mask], delta_target[mask]),
        interiorDetailCorrelationWithPhoto=dict(raw=correlation(raw_band[interior],source_band[interior]),
            after=correlation(after_band[interior],source_band[interior])),
        interiorBandRMS=dict(raw=float(np.sqrt(np.mean(raw_band[interior]**2))),
            photo=float(np.sqrt(np.mean(source_band[interior]**2))), after=float(np.sqrt(np.mean(after_band[interior]**2)))),
        note='Band energy/correlation describes this local patch only; it is not a recovered-detail percentage or proof of global quality. Correlation with the requested photographic delta checks encoding/provenance, not improvement.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Fresh output required; previous evidence is preserved')
    args.output.mkdir(parents=True)
    cv2.ocl.setUseOpenCL(False); cv2.setNumThreads(2)
    sources, checks = {}, []
    common_mask_path = args.input/'same-patch-common-mask.png'
    common = cv2.imread(str(common_mask_path), cv2.IMREAD_GRAYSCALE)
    if common is None:
        raise ValueError('Missing existing common mask')
    mask = common > 0
    height, width = mask.shape
    raw = None
    for index in [480,482,485]:
        path = args.input/f'patch-atlas2-photo{index}-native.png'
        image = cv2.imread(str(path), cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
        if image is None or image.shape != (height,width*2,3):
            raise ValueError('Existing native pair has unexpected dimensions')
        rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
        if raw is None:
            raw = rgb[:,:width].copy()
        if not np.array_equal(raw, rgb[:,:width]):
            raise ValueError('All controls must share byte-identical Raw ROI')
        sources[index] = rgb[:,width:].copy()
        checks.append(dict(file=str(path), sha256=digest(path)))
    checks.append(dict(file=str(common_mask_path), sha256=digest(common_mask_path)))
    distance = cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    phase = np.clip((distance-1)/12, 0, 1)
    alpha = phase*phase*(3-2*phase)
    raw_linear = linear(raw); raw_y = luma(raw_linear); raw_log = log_luma(raw_linear)
    save_rgb(args.output/'raw-before-native.png', raw)
    for index, photo in sources.items():
        save_rgb(args.output/f'photo{index}-aligned-native.png',photo)
    cv2.imwrite(str(args.output/'common-mask.png'),mask.astype(np.uint8)*255)
    cv2.imwrite(str(args.output/'alpha-12px.png'),np.rint(alpha*255).astype(np.uint8))
    variants, images = [], {}
    for index,sigma in [(482,2.),(482,4.),(480,4.),(485,4.)]:
        photo = sources[index]
        source_band = band(log_luma(linear(photo)), sigma)
        target_delta = alpha*(source_band-band(raw_log,sigma))
        new_y = np.maximum(np.exp(raw_log+target_delta)-1e-5,0)
        scale = np.divide(new_y,raw_y,out=np.ones_like(new_y),where=raw_y>1e-10)
        candidate_linear = raw_linear*scale[:,:,None]
        clipping = np.any((candidate_linear < 0) | (candidate_linear > 1),axis=2) & mask
        after = encode(candidate_linear)
        after[alpha == 0] = raw[alpha == 0]
        name = f'photo{index}-band06-{sigma:g}'
        destination = args.output/(name+'-after-native.png')
        save_rgb(destination,after); images[name] = after
        measurement = diagnostics(raw,after,photo,target_delta,alpha,mask,distance,sigma)
        measurement['outOfGamutPixelsBeforeEncoding'] = int(clipping.sum())
        interior = alpha > .999
        raw_band,after_band = band(raw_log,sigma),band(log_luma(linear(after)),sigma)
        measurement['referencePhotoBandCorrelations'] = {}
        for reference_index,reference in sources.items():
            reference_band = band(log_luma(linear(reference)),sigma)
            measurement['referencePhotoBandCorrelations'][str(reference_index)] = dict(
                usedAsDetailSource=reference_index == index,
                raw=correlation(raw_band[interior],reference_band[interior]),
                after=correlation(after_band[interior],reference_band[interior]))
        if measurement['outsideMaskChangedRGBPixels'] != 0:
            raise AssertionError('Raw outside the existing common mask changed')
        variants.append(dict(name=name,sourcePhotoIndex=index,smallSigmaPixels=.6,largeSigmaPixels=sigma,
            output=destination.name,measurements=measurement))
    panel([('RAW original',raw),('Foto482 alineada',sources[482]),
           ('Foto482 banda0.6-2',images['photo482-band06-2']),
           ('Foto482 banda0.6-4',images['photo482-band06-4'])],args.output/'comparison-native.png')
    panel([('RAW original',raw),('Control480 banda0.6-4',images['photo480-band06-4']),
           ('Foto482 banda0.6-4',images['photo482-band06-4']),
           ('Control485 banda0.6-4',images['photo485-band06-4'])],args.output/'controls-native.png')
    for check in checks:
        check['unchangedAfter'] = digest(Path(check['file'])) == check['sha256']
        if not check['unchangedAfter']:
            raise AssertionError('Existing aligned input changed')
    report=dict(schemaVersion=1,nativeDimensions=[width,height],commonMaskPixels=int(mask.sum()),
        fullyWeightedInteriorPixels=int(np.sum(alpha>.999)),
        experiment='Next experimental route only: real photographic band replacement in fixed Raw atlas coordinates; no product promotion/model/UV/library write.',
        formula='logY_after=logY_Raw+alpha*((G0.6(logY_photo)-Gs(logY_photo))-(G0.6(logY_Raw)-Gs(logY_Raw))); linear RGB Raw scaled uniformly by targetY/RawY, then sRGB8 encoding',
        colorAndBase='Raw chromaticity and frequencies outside the selected luminance band are retained before finite-mask/gamut/encoding effects; actual drift is measured, not assumed zero.',
        lowFrequencyColorMeasurement='Gaussian sigma12 on decoded linear RGB; continuous double-precision D65/sRGB->CIELAB, without intermediate8bit quantization.',
        boundary='Existing common mask only; inward distance smoothstep from1to13nativepixels; outside and alpha0 pixels restored byte-exactly to Raw.',
        sourceProvenance='Existing photo-to-atlas homographies/native pairs from native-patch-report.json; no new registration or resampling in this experiment.',
        alignmentCaveat='This local homography is approximate (photo482 fitting median0.676px, p90 1.272px); high-frequency transfer can expose misregistration/ghosting. The rectangle is not established to be a safe UV island.',
        sourceDetail='Every added/subtracted band sample comes from the aligned photographic residual relative to its own Gaussian base; no unsharp amplitude boost, generative model or artificial image detail.',
        inputs=checks,variants=variants)
    (args.output/'report.json').write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    print(json.dumps(report,indent=2,allow_nan=False))


if __name__ == '__main__':
    main()
