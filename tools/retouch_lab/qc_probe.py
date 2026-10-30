"""精修质检探针：对任意 before/after 图片对跑一遍商业质检门禁。

这是 `scripts/` 之外的一个独立小工具，**不参与 app 构建**。它复用
`tools/retouch_lab` 的 Python 参考实现——那份实现与 Swift 的
`RetouchQualityGate.swift` 是同一套公式（阈值、代理尺度 1100、逐像素 ΔE00
全部一一对应），所以这里跑出来的数就是手机上手会看到的数。

用法：
    # 评估已有的一对图（精修前后）
    python -m tools.retouch_lab.qc_probe --before a.jpg --after b.jpg

    # 人像：自动生成肤色遮罩；风景：--skin all
    python -m tools.retouch_lab.qc_probe --before a.jpg --after b.jpg --skin auto --ev 0.21

    # 同时模拟「局部肤色拉回」（V22 新增的那一级），看 p95 能不能压回门禁内
    python -m tools.retouch_lab.qc_probe --before a.jpg --after b.jpg --fix

输出：一张指标表 + 新旧门禁结论 + （--fix 时）拉回前后的对比。
"""

from __future__ import annotations

import argparse
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools.retouch_lab import ops, pipeline, portrait  # noqa: E402

# 与 RetouchQualityGate.swift 完全一致的阈值
LIMITS = {
    "texture_retention": (0.50, 1.15),     # 区间
    "skin_tone_de": (None, 3.00),          # 上限
    "skin_luma_shift": (None, 18.0),
    "clipping_skin": (None, 0.002),
    "clipping_full": (None, 0.0100),
    "seam_ratio": (0.70, 1.30),            # |x-1| <= 0.30
    "ssim": (0.85, None),
    "skin_pixel_de_p95_info": (None, 6.00),  # V22 新增：p95 门禁
}

LABELS = {
    "texture_retention": "纹理保留",
    "skin_tone_de": "肤色 ΔE00",
    "skin_pixel_de_p95_info": "肤色 ΔE P95",
    "skin_luma_shift": "肤色明度偏移",
    "clipping_skin": "肤色裁切",
    "clipping_full": "整体裁切",
    "seam_ratio": "接缝比例",
    "ssim": "SSIM",
    "blemish_clearance": "瑕疵清除率",
    "spots_before": "检测瑕疵数",
}


def load(path: str, max_edge: int = 2400) -> np.ndarray:
    im = Image.open(path).convert("RGB")
    w, h = im.size
    scale = min(1.0, max_edge / float(max(w, h)))
    if scale < 1.0:
        im = im.resize((int(round(w * scale)), int(round(h * scale))), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def save(path: str, rgb: np.ndarray, quality: int = 95) -> None:
    Image.fromarray(ops.to_uint8(rgb)).save(path, quality=quality, subsampling=1)


def auto_skin_soft(rgb: np.ndarray) -> np.ndarray:
    """YCbCr + HSV 双条件的近似肤色遮罩（0...1 软边）。

    注意：这是**探针用的近似**，不是 app 里的 Vision 遮罩。它的作用是在没有
    Vision 的机器上判断「这块算不算皮肤」，方向和 app 一致（YCbCr 的 Cr/Cb
    窗口 + HSV 的低饱和暖色窗口），但边界精度不如 Vision。
    """
    ycc = ops.rgb_to_ycbcr(rgb)
    cb = ycc[..., 1]          # 0...1，以 0.5 为中心（ops 里 +0.5）
    cr = ycc[..., 2]
    hsv = ops.hue_sat_value(rgb)
    hue = hsv[..., 0]         # 度，0...360
    sat = hsv[..., 1]
    val = hsv[..., 2]
    # 标准肤色窗口：Cb 0.26…0.52、Cr 0.50…0.72；色相 2°…55°（暖色带），别太饱和
    ycc_mask = (cb > 0.26) & (cb < 0.52) & (cr > 0.50) & (cr < 0.72)
    hsv_mask = (hue > 2.0) & (hue < 55.0) & (sat > 0.10) & (sat < 0.75) & (val > 0.10)
    mask = (ycc_mask & hsv_mask).astype(np.float32)
    mask = ops.morph_open(mask, 2)
    mask = ops.morph_close(mask, 4)
    return ops.feather(mask, 3.0)


def gate(original: np.ndarray, result: np.ndarray, skin: np.ndarray,
         ev: float, portrait: bool, wb: np.ndarray | None) -> "pipeline.QCReport":
    return pipeline.quality_gate(original, result, skin,
                                 blemish_clearance=1.0,
                                 exposure_ev=ev,
                                 spots_before=0,
                                 white_balance_gains=wb,
                                 portrait=portrait)


def local_pull_skin_tone(original: np.ndarray, result: np.ndarray, skin_soft: np.ndarray,
                         ev: float, wb: np.ndarray | None = None,
                         target_de: float = 4.0, max_iter: int = 2):
    """V22 的「局部肤色拉回」Python 复刻（与 Swift `pullSkinToneLocally` 同一套公式）。

    逐像素 ΔE00 → 权重 smoothstep(3,8,ΔE)×肤色软边 → 只对权重>0.5 的像素算 Lab 中位数
    增益（阻尼 0.85、增益夹 0.70...1.45）→ 羽化后只乘该区域；≤2 轮。
    """
    aligned = np.clip(original * (2.0 ** ev), 0.0, 1.0)
    if wb is not None:
        aligned = np.clip(aligned * wb[None, None, :], 0.0, 1.0)
    lab_o = ops.rgb_to_lab(aligned)
    sel_hard = skin_soft > 0.6
    if sel_hard.sum() < 500:
        return result, 0.0, 0

    work = result.copy()
    best_work = result.copy()
    rounds = 0
    p95 = float(np.percentile(ops.delta_e_2000(lab_o, ops.rgb_to_lab(work))[sel_hard], 95))
    best_p95 = p95
    for _ in range(max_iter):
        lab_r = ops.rgb_to_lab(work)
        de = ops.delta_e_2000(lab_o, lab_r)
        p95 = float(np.percentile(de[sel_hard], 95))
        if not np.isfinite(p95) or p95 <= target_de:
            break
        t = np.clip((de - 3.0) / (8.0 - 3.0), 0.0, 1.0)
        weight = (t * t * (3.0 - 2.0 * t)) * skin_soft
        selected = weight > 0.5
        if selected.sum() < 16:
            break
        target_median = np.median(lab_o[selected], axis=0)
        current_median = np.median(lab_r[selected], axis=0)
        target_rgb = ops.lab_to_rgb(target_median[None, None, :])[0, 0]
        current_rgb = ops.lab_to_rgb(current_median[None, None, :])[0, 0]
        raw = np.clip(target_rgb / np.maximum(current_rgb, 0.02), 0.70, 1.45)
        gains = 1.0 + (raw - 1.0) * 0.85
        graded = np.clip(work * gains[None, None, :], 0.0, 1.0)
        feather_sigma = max(2.0, work.shape[1] / 220.0)
        m = ops.feather(weight, feather_sigma)[..., None]
        proposed = np.clip(graded * m + work * (1.0 - m), 0.0, 1.0)
        verified = float(np.percentile(ops.delta_e_2000(lab_o, ops.rgb_to_lab(proposed))[sel_hard], 95))
        if not np.isfinite(verified) or verified >= p95 or verified >= best_p95:
            break
        work = proposed
        best_work = proposed
        best_p95 = verified
        rounds += 1

    return best_work, best_p95, rounds


SCENE_LIMITS = {
    "texture_retention": (0.60, 1.20),
    "clipping_full": (None, 0.0100),
    "ssim": (0.85, None),
}


def judge(metrics: dict, scene: bool = False) -> tuple[bool, list[str]]:
    problems = []
    active = SCENE_LIMITS if scene else LIMITS
    for key, (lo, hi) in active.items():
        if key not in metrics:
            continue
        value = float(metrics[key])
        if lo is not None and value < lo:
            problems.append(f"{LABELS.get(key, key)} {value:.3f} 低于下限 {lo:.3f}")
        if hi is not None:
            exceeded = abs(value - 1.0) > 0.30 if key == "seam_ratio" else value > hi
            if exceeded:
                problems.append(f"{LABELS.get(key, key)} {value:.3f} 超过上限 {hi:.3f}")
    return (len(problems) == 0), problems


def print_table(metrics: dict, scene: bool = False) -> None:
    for key in (SCENE_LIMITS if scene else LIMITS):
        if key not in metrics:
            continue
        value = float(metrics[key])
        lo, hi = (SCENE_LIMITS if scene else LIMITS)[key]
        if key == "seam_ratio":
            limit_text = "0.70…1.30"
            ok = abs(value - 1.0) <= 0.30
        elif lo is None:
            limit_text = f"≤ {hi:.4g}"
            ok = value <= hi
        elif hi is None:
            limit_text = f"≥ {lo:.4g}"
            ok = value >= lo
        else:
            limit_text = f"{lo:.4g}…{hi:.4g}"
            ok = lo <= value <= hi
        flag = "PASS" if ok else "FAIL"
        print(f"  {LABELS.get(key, key):<12} {value:>9.4f}   {limit_text:<12} {flag}")


def main() -> int:
    parser = argparse.ArgumentParser(description="对一对精修前后图片跑商业质检门禁")
    parser.add_argument("--before", required=True, help="原图（或精修前）")
    parser.add_argument("--after", required=True, help="精修结果")
    parser.add_argument("--skin", choices=["auto", "all"], default="auto",
                        help="auto=近似肤色遮罩（人像）；all=整图（风景）")
    parser.add_argument("--ev", type=float, default=0.0, help="曝光对齐 EV（门禁用它对齐参考图）")
    parser.add_argument("--portrait", action="store_true", help="按人像口径判定")
    parser.add_argument("--scene", action="store_true",
                        help="按风景口径判定（纹理 0.60…1.20，且不查肤色项）——与 Python 参考实现一致")
    parser.add_argument("--wb", choices=["auto", "none"], default="auto",
                        help="auto=用参考实现同一套自动白平衡增益对齐参考图（默认，和 app 同口径）")
    parser.add_argument("--fix", action="store_true", help="额外模拟局部肤色拉回并重新判定")
    parser.add_argument("--out", default="", help="--fix 时把拉回结果写到这里")
    args = parser.parse_args()

    before = load(args.before)
    after = load(args.after)
    if before.shape[:2] != after.shape[:2]:
        h = min(before.shape[0], after.shape[0])
        w = min(before.shape[1], after.shape[1])
        before = before[:h, :w]
        after = after[:h, :w]
        print(f"注意：两图尺寸不同，已裁到共同区域 {w}x{h}")

    skin = np.ones(before.shape[:2], dtype=np.float32) if args.skin == "all" \
        else auto_skin_soft(before)
    coverage = float((skin > 0.6).mean())
    print(f"图片 {before.shape[1]}x{before.shape[0]} · 肤色覆盖 {coverage*100:.1f}% · 曝光对齐 {args.ev:+.3f} EV")

    wb = portrait._auto_white_balance(before) if args.wb == "auto" else None
    if wb is not None:
        print("白平衡增益（对齐参考图）：" + ", ".join(f"{v:.3f}" for v in wb))
    portrait_mode = args.portrait and not args.scene
    report = gate(before, after, skin, args.ev, portrait_mode, wb)
    metrics = dict(report.metrics)
    print("\n== 当前门禁（含 V22 的 p95 6.00）==")
    print_table(metrics, scene=args.scene)
    passed, problems = judge(metrics, scene=args.scene)
    print(f"结论：{'通过' if passed else '未通过'}")
    for line in problems:
        print("  - " + line)
    if getattr(report, "notes", None):
        for note in report.notes:
            print("  note:", note)

    if args.fix:
        print("\n== 模拟局部肤色拉回（V22 新增那一级）==")
        fixed, p95_after, rounds = local_pull_skin_tone(before, after, skin, args.ev, wb)
        fixed_report = gate(before, fixed, skin, args.ev, portrait_mode, wb)
        fixed_metrics = dict(fixed_report.metrics)
        print_table(fixed_metrics, scene=args.scene)
        fixed_passed, fixed_problems = judge(fixed_metrics, scene=args.scene)
        print(f"拉回 {rounds} 轮 · p95 {metrics.get('skin_pixel_de_p95_info', 0):.3f} → {p95_after:.3f}")
        print(f"结论：{'通过' if fixed_passed else '仍未通过'}")
        for line in fixed_problems:
            print("  - " + line)
        if args.out:
            save(args.out, fixed)
            print("已写出：" + args.out)

    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
