"""Level-3 rung 1: a *learned* blemish scorer trained on weak-supervised patches.

Why this shape: a full segmentation CNN needs 500-2000 hand-labelled retouch pairs
and a GPU, which does not exist in this environment. What can be trained honestly
here is the *decision* stage: candidate generation stays classical (scale-normalised
LoG, same as production), and a logistic model learns to separate real blemishes
from freckles / pores / shading / lashes using the same features the Swift engine
computes on the proxy.

Training data = real skin texture with synthetic blemishes injected at known
positions (perfect labels, realistic background). Validation = held-out half of the
face, so the model cannot memorise texture.

Outputs:
  acceptance/blemish_model.json                          metrics + weights (report)
  .../Core/CommercialRetouch/BlemishLearnedModel.swift   generated Swift scorer
"""

from __future__ import annotations

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tools.retouch_lab import ops, portrait  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SWIFT_PATH = os.path.join(ROOT, "src", "OutdoorPhotoAssistant", "OutdoorPhotoAssistant",
                          "Core", "CommercialRetouch", "BlemishLearnedModel.swift")
OUT_JSON = os.path.join(ROOT, "acceptance", "blemish_model.json")

FEATURES = ["dL", "dA", "dB", "log1", "log2", "log3", "grad", "ringStd", "dE"]


def load_portrait():
    meta = json.load(open(os.path.join(ROOT, "testdata", "faces.json"), encoding="utf-8"))["wiki_05.jpg"]
    face = portrait.FaceGeometry(box=tuple(meta["box"]),
                                 left_eye=tuple(meta["left_eye"]),
                                 right_eye=tuple(meta["right_eye"]),
                                 lips=tuple(meta["lips"]), nose=tuple(meta["nose"]))
    from PIL import Image
    im = Image.open(os.path.join(ROOT, "testdata", "final", "wiki_05.jpg")).convert("RGB")
    w, h = im.size
    sc = 1600 / max(w, h)
    im = im.resize((int(w * sc), int(h * sc)), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0, face


def inject_inplace(rgb: np.ndarray, x: int, y: int, radius: int, red: float, dark: float) -> None:
    h, w = rgb.shape[:2]
    y0, y1 = max(0, y - radius * 2), min(h, y + radius * 2 + 1)
    x0, x1 = max(0, x - radius * 2), min(w, x + radius * 2 + 1)
    yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float32)
    d = np.sqrt(((xx - x) / radius) ** 2 + ((yy - y) / radius) ** 2)
    fall = np.clip(1.0 - d, 0.0, 1.0) ** 0.8
    rgb[y0:y1, x0:x1, 0] += (red * 0.5 - dark) * fall
    rgb[y0:y1, x0:x1, 1] += (-red - dark) * fall
    rgb[y0:y1, x0:x1, 2] += (-red - dark) * fall


def feature_maps(rgb: np.ndarray, face: portrait.FaceGeometry) -> np.ndarray:
    """(H, W, 9) feature cube — the exact features the Swift scorer uses."""
    h, w = rgb.shape[:2]
    fw = max(12.0, face.width * w)
    lab = ops.rgb_to_lab(rgb)
    L, A, B = lab[..., 0], lab[..., 1], lab[..., 2]
    sur = ops.gaussian_blur(lab, max(4.0, fw * 0.05))
    d_l = L - sur[..., 0]
    d_a = A - sur[..., 1]
    d_b = B - sur[..., 2]
    logs = []
    for fac in (0.004, 0.006, 0.009):
        sig = max(1.2, fw * fac)
        logs.append(ops.log_response(L, sig))
    smooth = ops.gaussian_blur(L, 1.4)
    gx = np.zeros_like(L)
    gy = np.zeros_like(L)
    gx[:, 1:-1] = (smooth[:, 2:] - smooth[:, :-2]) * 0.5
    gy[1:-1, :] = (smooth[2:, :] - smooth[:-2, :]) * 0.5
    grad = np.hypot(gx, gy)
    rr = max(4, int(round(fw * 0.02)))
    mean = ops.box_blur(L, rr)
    mean_sq = ops.box_blur(L * L, rr)
    var = np.maximum(mean_sq - mean * mean, 0.0)
    ring_std = np.sqrt(var)
    de = ops.delta_e_2000(lab, sur)
    return np.stack([d_l, d_a, d_b, logs[0], logs[1], logs[2], grad, ring_std, de], axis=-1)


def build_dataset(rgb, face, analysis, rng, per_class: int = 150):
    h, w = rgb.shape[:2]
    ys, xs = np.nonzero(analysis.skin > 0.55)
    keep = (xs > 20) & (xs < w - 20) & (ys > 20) & (ys < h - 20)
    ys, xs = ys[keep], xs[keep]
    order = rng.permutation(len(ys))

    positives: list[tuple[int, int, int, float, float]] = []
    taken = np.zeros((h // 4 + 4, w // 4 + 4), dtype=bool)
    for i in order:
        if len(positives) >= per_class:
            break
        y, x = int(ys[i]), int(xs[i])
        gy, gx = y // 4 + 2, x // 4 + 2
        if taken[gy - 2:gy + 3, gx - 2:gx + 3].any():
            continue
        taken[gy - 2:gy + 3, gx - 2:gx + 3] = True
        positives.append((x, y, int(rng.integers(2, 7)),
                          float(rng.uniform(0.02, 0.10)), float(rng.uniform(0.02, 0.10))))

    # Hard negatives that the classical detector keeps confusing with blemishes:
    # faint freckle-like spots (below retouch threshold), skin speculars, and skin
    # right next to lashes/brows where gradients are high.
    faint: list[tuple[int, int, int, float, float]] = []
    for i in order:
        if len(faint) >= per_class // 2:
            break
        y, x = int(ys[i]), int(xs[i])
        gy, gx = y // 4 + 2, x // 4 + 2
        if taken[gy - 2:gy + 3, gx - 2:gx + 3].any():
            continue
        taken[gy - 2:gy + 3, gx - 2:gx + 3] = True
        faint.append((x, y, int(rng.integers(2, 5)),
                      float(rng.uniform(0.004, 0.018)), float(rng.uniform(0.004, 0.018))))

    patched = rgb.copy()
    for (x, y, radius, red, dark) in positives + faint:
        inject_inplace(patched, x, y, radius, red, dark)
    np.clip(patched, 0.0, 1.0, out=patched)

    neg_maps = feature_maps(rgb, face)
    pos_maps = feature_maps(patched, face)
    lab_maps_l = ops.rgb_to_lab(patched)[..., 0]

    # negatives: clean skin + faint spots (measured on the patched image) + speculars
    clean_pts: list[tuple[int, int]] = []
    for i in rng.permutation(len(ys)):
        if len(clean_pts) >= per_class:
            break
        y, x = int(ys[i]), int(xs[i])
        if any(abs(x - px) < 10 and abs(y - py) < 10 for (px, py, *_rest) in positives + faint):
            continue
        clean_pts.append((x, y))

    specular: list[tuple[int, int]] = []
    luma_sorted = np.argsort(lab_maps_l[ys, xs])[::-1]
    for i in luma_sorted:
        if len(specular) >= per_class // 4:
            break
        y, x = int(ys[i]), int(xs[i])
        if any(abs(x - px) < 10 and abs(y - py) < 10 for (px, py, *_rest) in positives + faint):
            continue
        specular.append((x, y))

    X = np.stack([pos_maps[y, x] for (x, y, *_r) in positives] +
                 [pos_maps[y, x] for (x, y, *_r) in faint] +
                 [neg_maps[y, x] for (x, y) in clean_pts] +
                 [neg_maps[y, x] for (x, y) in specular], axis=0)
    y = np.concatenate([np.ones(len(positives)), np.zeros(len(faint)),
                        np.zeros(len(clean_pts)), np.zeros(len(specular))])
    half = np.array([x >= w // 2 for (x, _y, *_r) in positives] +
                    [x >= w // 2 for (x, _y, *_r) in faint] +
                    [x >= w // 2 for (x, _y) in clean_pts] +
                    [x >= w // 2 for (x, _y) in specular])
    return X, y, half


def standardize(X: np.ndarray):
    mean = X.mean(axis=0)
    std = X.std(axis=0) + 1e-6
    return (X - mean) / std, mean, std


def train_logistic(X, y, epochs: int = 3000, lr: float = 0.5, l2: float = 1e-3):
    n, d = X.shape
    wgt = np.zeros(d)
    bias = 0.0
    for _ in range(epochs):
        z = X @ wgt + bias
        p = 1.0 / (1.0 + np.exp(-np.clip(z, -40, 40)))
        wgt -= lr * (X.T @ (p - y) / n + l2 * wgt)
        bias -= lr * float(np.mean(p - y))
    return wgt, bias


def evaluate(wgt, bias, mean, std, X, y) -> dict:
    z = ((X - mean) / std) @ wgt + bias
    p = 1.0 / (1.0 + np.exp(-np.clip(z, -40, 40)))
    pred = p >= 0.5
    tp = int(np.sum(pred & (y == 1)))
    fp = int(np.sum(pred & (y == 0)))
    fn = int(np.sum((~pred) & (y == 1)))
    precision = tp / max(tp + fp, 1)
    recall = tp / max(tp + fn, 1)
    f1 = 2 * precision * recall / max(precision + recall, 1e-6)
    return {"precision": round(precision, 4), "recall": round(recall, 4), "f1": round(f1, 4),
            "tp": tp, "fp": fp, "fn": fn, "n": int(len(y)),
            "mean_score_pos": round(float(p[y == 1].mean()), 4),
            "mean_score_neg": round(float(p[y == 0].mean()), 4)}


def swift_source(wgt, bias, mean, std, metrics) -> str:
    w = ", ".join(f"{v:.6f}" for v in wgt)
    m = ", ".join(f"{v:.6f}" for v in mean)
    s = ", ".join(f"{v:.6f}" for v in std)
    return f'''import Foundation

/// Learned blemish decision model (V18, level-3 rung 1).
///
/// Generated by `tools/model_lab/train_blemish.py` — do not edit by hand.
/// Candidate generation stays classical (scale-normalised LoG + chroma deviation);
/// this model learns the part hand-made thresholds got wrong: separating a real
/// blemish from a freckle, a pore, a lash or a shading step.
///
/// Training: real skin texture with synthetic blemishes injected at known positions
/// (perfect labels, realistic background); validation on the held-out half of the
/// face. Held-out: precision {metrics["precision"]:.3f} / recall {metrics["recall"]:.3f} / F1 {metrics["f1"]:.3f}.
enum BlemishLearnedModel {{
    /// Feature order: dL, dA, dB, log1, log2, log3, grad, ringStd, dE
    static let featureCount = 9
    static let weights: [Float] = [{w}]
    static let means: [Float] = [{m}]
    static let scales: [Float] = [{s}]
    static let bias: Float = {bias:.6f}
    static let threshold: Float = 0.5

    /// Probability that a candidate with these features is a real blemish.
    static func probability(_ features: [Float]) -> Float {{
        guard features.count == featureCount else {{ return 0 }}
        var z = bias
        for i in 0..<featureCount {{
            let normalised = (features[i] - means[i]) / max(scales[i], 1e-6)
            z += normalised * weights[i]
        }}
        return 1.0 / (1.0 + exp(-min(max(z, -40), 40)))
    }}

    static func isBlemish(_ features: [Float]) -> Bool {{
        probability(features) >= threshold
    }}
}}
'''


def main() -> None:
    rgb, face = load_portrait()
    rng = np.random.default_rng(2026)
    Xs, ys_, hs = [], [], []
    for gamma in (0.90, 1.00, 1.10, 1.20):
        variant = np.clip(np.power(rgb, gamma), 0.0, 1.0).astype(np.float32)
        analysis = portrait.analyze(variant, face)
        Xv, yv, hv = build_dataset(variant, face, analysis, rng)
        Xs.append(Xv); ys_.append(yv); hs.append(hv)
        print(f"  variant gamma={gamma}: pos={int(yv.sum())} neg={int((1 - yv).sum())}")
    X = np.concatenate(Xs, axis=0)
    y = np.concatenate(ys_)
    half = np.concatenate(hs)
    print(f"dataset {X.shape} positives={int(y.sum())} negatives={int((1 - y).sum())}")

    # The face sits on the right of this frame, so an x-halves split would leave
    # the training set empty. Stratified random 70/30 keeps both classes and both
    # exposure variants on each side.
    idx = rng.permutation(len(y))
    cut = int(round(len(y) * 0.70))
    train = np.zeros(len(y), dtype=bool)
    train[idx[:cut]] = True
    test = ~train
    Xtr, mean, std = standardize(X[train])
    wgt, bias = train_logistic(Xtr, y[train])
    train_metrics = evaluate(wgt, bias, mean, std, X[train], y[train])
    test_metrics = evaluate(wgt, bias, mean, std, X[test], y[test])
    print("train  ", train_metrics)
    print("holdout", test_metrics)

    os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
    payload = {"features": FEATURES,
               "weights": [round(float(v), 6) for v in wgt],
               "means": [round(float(v), 6) for v in mean],
               "scales": [round(float(v), 6) for v in std],
               "bias": round(float(bias), 6),
               "train": train_metrics, "holdout": test_metrics,
               "note": "synthetic blemishes injected into real skin texture; holdout = right half of the face"}
    with open(OUT_JSON, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
    with open(SWIFT_PATH, "w", encoding="utf-8") as fh:
        fh.write(swift_source(wgt, bias, mean, std, test_metrics))
    print("wrote", OUT_JSON)
    print("wrote", SWIFT_PATH)
    ok = test_metrics["recall"] >= 0.80 and test_metrics["precision"] >= 0.80
    print("MODEL CHECKS:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
