"""Read-only SIFT correspondence check against native-camera USDZ renders.

No homography, image registration, camera fitting, reconstruction or source edits.
Source features are computed once per view and reused for both models. The main
comparison uses exactly the same source-keypoint IDs matched by both models.
SIFT matching is an alignment check, not a measurement of global image sharpness.
"""
import argparse
import json
from pathlib import Path
import cv2
import numpy as np
from photogrammetry_rectification import lens_model, forward_xy, inverse_radius


def metrics(delta, center, source):
    if len(source) == 0:
        return dict(count=0, medianPixels=None, p75Pixels=None, p90Pixels=None,
                    meanPixels=None, outerHalfMedianPixels=None,
                    within2Pixels=0, within5Pixels=0)
    errors = np.linalg.norm(delta, axis=1)
    radius = np.linalg.norm(source - center, axis=1)
    outer = radius >= np.median(radius)
    return dict(count=len(errors), medianPixels=float(np.median(errors)), p75Pixels=float(np.percentile(errors, 75)),
                p90Pixels=float(np.percentile(errors, 90)), meanPixels=float(np.mean(errors)),
                outerHalfMedianPixels=float(np.median(errors[outer])), within2Pixels=int(np.sum(errors < 2)),
                within5Pixels=int(np.sum(errors < 5)))


def ratio_matches(matcher, left, right):
    if left is None or right is None or len(left) == 0 or len(right) < 2:
        return {}
    return {pair[0].queryIdx: pair[0].trainIdx for pair in matcher.knnMatch(left, right, k=2)
            if len(pair) == 2 and pair[0].distance < .75 * pair[1].distance}


def mutual_matches(matcher, source, render):
    forward = ratio_matches(matcher, source, render)
    reverse = ratio_matches(matcher, render, source)
    return {i: j for i, j in forward.items() if reverse.get(j) == i}


def coordinates(source, model):
    center = model[0]
    x, y = forward_xy(source[:, 0], source[:, 1], model)
    radius = np.linalg.norm(source-center, axis=1)
    ratio = np.divide(inverse_radius(radius, model), radius,
                      out=np.ones_like(radius), where=radius > 0)
    return dict(original=source,
                appleForward=np.stack([x, y], axis=1),
                correctedNativeLUT=center+(source-center)*ratio[:, None])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--calibration', required=True, type=Path)
    parser.add_argument('--dataset', required=True, type=Path)
    parser.add_argument('--renders', required=True, type=Path)
    parser.add_argument('--baseline-prefix', default='raw')
    parser.add_argument('--candidate-prefix', default='candidate')
    parser.add_argument('--baseline-label', default='RAW')
    parser.add_argument('--candidate-label', default='CANDIDATO')
    parser.add_argument('--samples', nargs='+', type=int, default=[0, 283, 482])
    args = parser.parse_args()
    cv2.setNumThreads(2)
    cameras = json.loads(args.calibration.read_text())['cameras']
    sift = cv2.SIFT_create()
    matcher = cv2.BFMatcher(cv2.NORM_L2)
    report = dict(schemaVersion=2, openCVVersion=cv2.__version__,
                  method='Full-native-resolution SIFT, mutual nearest-neighbor Lowe ratio0.75; source features computed once per view and reused. No homography/registration/camera fitting.',
                  scope='Alignment and count of matched source features for these viewpoints only. SIFT counts/errors do not establish global sharpness, perceptual quality or a globally superior model.',
                  commonCohortRule='Exact intersection of source-keypoint IDs mutually matched to both renders; no geometric residual threshold or favored model selects this cohort.',
                  referencePanel='Original source photo is displayed without resampling/warping; native LUT correction is applied to feature coordinates only for the alignment metrics.',
                  hypothesisCoordinates=dict(original='Unchanged source keypoint p',
                      appleForward='q=center+(p-center)*(1+nativeLUT(radius))',
                      correctedNativeLUT='Exact piecewise-radial inverse of Apple forward(p); direction validated against native geometry in the earlier controls'),
                  models=dict(baseline=dict(prefix=args.baseline_prefix, label=args.baseline_label),
                              candidate=dict(prefix=args.candidate_prefix, label=args.candidate_label)), views=[])
    for sample in args.samples:
        camera = next(c for c in cameras if c['sampleID'] == sample)
        source_path = args.dataset / camera['sourceFile']
        source_image = cv2.imread(str(source_path), cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
        if source_image is None:
            raise ValueError('Missing source image')
        source_keys, source_descriptors = sift.detectAndCompute(cv2.cvtColor(source_image, cv2.COLOR_BGR2GRAY), None)
        source = np.asarray([key.pt for key in source_keys], np.float64).reshape(-1, 2)
        if len(source) == 0:
            raise ValueError('No source features; alignment cannot be measured')
        model = lens_model(camera, source_image.shape[1], source_image.shape[0])
        center = model[0]
        hypotheses = coordinates(source, model)
        result = dict(sampleID=sample, frameID=camera['frameID'], source=str(source_path),
                      sourceFeatures=len(source_keys), models={})
        matched = {}
        render_points = {}
        render_images = {}
        for name, prefix in [('baseline', args.baseline_prefix), ('candidate', args.candidate_prefix)]:
            render_path = args.renders / f'{prefix}-camera-{sample}.png'
            render_image = cv2.imread(str(render_path), cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
            if render_image is None or source_image.shape != render_image.shape:
                raise ValueError(f'Source/render raster mismatch: {render_path}')
            render_keys, render_descriptors = sift.detectAndCompute(cv2.cvtColor(render_image, cv2.COLOR_BGR2GRAY), None)
            pairs = mutual_matches(matcher, source_descriptors, render_descriptors)
            ids = np.asarray(sorted(pairs), dtype=np.int64)
            targets = np.asarray([render_keys[pairs[i]].pt for i in ids], np.float64).reshape(-1, 2)
            matched[name] = pairs
            render_points[name] = np.asarray([key.pt for key in render_keys], np.float64).reshape(-1, 2)
            render_images[name] = render_image
            result['models'][name] = dict(render=str(render_path), renderFeatures=len(render_keys),
                mutualMatches=len(pairs), matchedSourceFeatureFraction=len(pairs)/len(source_keys),
                sourceKeypointIDs=ids.tolist(),
                allMatchedFeatures={hypothesis: metrics(points[ids]-targets, center, source[ids])
                                    for hypothesis, points in hypotheses.items()})
        common = np.asarray(sorted(set(matched['baseline']).intersection(matched['candidate'])), dtype=np.int64)
        common_metrics = {}
        for name in ['baseline', 'candidate']:
            targets = np.asarray([render_points[name][matched[name][i]] for i in common], np.float64).reshape(-1, 2)
            common_metrics[name] = {
                hypothesis: metrics(points[common]-targets, center, source[common])
                for hypothesis, points in hypotheses.items()}
            result['models'][name]['exclusiveMutualMatches'] = len(matched[name])-len(common)
        result['commonSourceCohort'] = dict(count=len(common), sourceKeypointIDs=common.tolist(),
            sourceCoordinatesPixels=source[common].tolist(), models=common_metrics)
        report['views'].append(result)
        panels=[]
        for title, image in [('FOTO ORIGINAL', source_image),
                (args.baseline_label+' - misma camara', render_images['baseline']),
                (args.candidate_label+' - misma camara', render_images['candidate'])]:
            width=1280; height=round(image.shape[0]*width/image.shape[1])
            panel=np.full((height+48,width,3),22,np.uint8)
            panel[48:]=cv2.resize(image,(width,height),interpolation=cv2.INTER_AREA)
            cv2.putText(panel,title,(15,32),cv2.FONT_HERSHEY_SIMPLEX,.7,(255,255,255),1,cv2.LINE_AA)
            panels.append(panel)
        if not cv2.imwrite(str(args.renders/f'photo-baseline-candidate-camera-{sample}.png'), np.concatenate(panels,axis=1)):
            raise ValueError('Could not save the comparison panel')
        print(json.dumps(dict(sampleID=sample, sourceFeatures=len(source_keys),
            mutualMatches={name: len(pairs) for name, pairs in matched.items()}, commonSourceFeatures=len(common),
            correctedNativeLUT={name: values['correctedNativeLUT'] for name, values in common_metrics.items()})), flush=True)
    destination=args.renders/'source-alignment-report.json'
    temporary=destination.with_name('.'+destination.name+'.tmp')
    temporary.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    temporary.replace(destination)
    print('completed',destination)


if __name__ == '__main__':
    main()
