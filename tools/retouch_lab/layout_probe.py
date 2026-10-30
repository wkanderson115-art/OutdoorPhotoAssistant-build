"""CaptureLayout.plan 的 Python 复刻：逐机型算「取景框多大 / 会不会溢出 / 占多少」。

用途：本机没有 swiftc，用这个脚本把布局数学先跑通，给出具体数字（谁挤谁、差多少），
再让 UI 按数字接线。Swift 侧同一份公式在 tests/layout/main.swift 里断言。

安全区假设（pt）：
  iPhone 15（393×852）：状态栏 59、底部 34、横屏左右 59 / 底部 21
  iPhone SE3（375×667）：状态栏 20、底部 0、横屏 0/0
快门条（safeAreaInset）高度：圆形 76 + 上下 padding 10*2 + 4 = 100；横屏浮层不占高度
"""
from __future__ import annotations

import itertools

TOP_BAR = 52
SHUTTER_BAR = 100


def fit(aspect: float, w: float, h: float) -> tuple[float, float]:
    if not (aspect > 0 and w > 0 and h > 0):
        return (0.0, 0.0)
    width = min(w, h * aspect)
    return (width, width / aspect)


def plan(avail_w, avail_h, landscape, aspect, bottom_bar, pad=8, spacing=8):
    top = TOP_BAR
    side = pad * 2
    usable_h = max(0, avail_h - top - bottom_bar - spacing)
    pw, ph = fit(aspect, max(0, avail_w - side), usable_h)
    consumed = top + bottom_bar + spacing + ph
    overflow = max(0, consumed - avail_h)
    fill = (pw * ph) / max(1, avail_w * avail_h)
    return dict(pw=pw, ph=ph, overflow=overflow, fill=fill, usable_h=usable_h)


DEVICES = {
    "iPhone 15": dict(w=393, h=852, top=59, bottom=34, ls=59, lb=21),
    "iPhone 15 Pro Max": dict(w=430, h=932, top=59, bottom=34, ls=59, lb=21),
    "iPhone SE3": dict(w=375, h=667, top=20, bottom=0, ls=0, lb=0),
    "iPhone 13 mini": dict(w=375, h=812, top=50, bottom=34, ls=50, lb=21),
}

# 竖屏控制区实测高度（含导演条 + 5 行控制区；V25 是 5 行，V26 目标压到 2 行）
RESERVE_V25 = 286
RESERVE_V26 = 120

CASES = [
    ("竖屏 V25（5 行控制区）", "portrait", RESERVE_V25, 0.75),
    ("竖屏 V26（2 行控制区）", "portrait", RESERVE_V26, 0.75),
    ("横屏 V25（右侧 250pt 栏）", "landscape", SHUTTER_BAR, 4 / 3),
    ("横屏 V26（浮层控制，快门仍占高度）", "landscape", 0, 4 / 3),
    ("横屏 V27（快门浮层，不占布局）", "landscape-overlay", 0, 4 / 3),
]


def main() -> None:
    print(f"{'机型':<20}{'场景':<26}{'可用区':>14}{'取景框':>14}{'溢出':>8}{'占比':>8}")
    print("-" * 92)
    for (label, mode, bottom, aspect) in CASES:
        for name, d in DEVICES.items():
            if mode == "portrait":
                avail_w = d["w"]
                avail_h = d["h"] - d["top"] - d["bottom"] - SHUTTER_BAR
                # 竖屏控制区在布局流里
                bottom_bar = bottom
            elif mode == "landscape":
                # 横屏：屏幕宽高对调（852×393），左右安全区扣宽度，底部安全区扣高度；
                # 这个场景里快门条仍然吃掉 100pt 布局高度
                # 旧实现：右侧 250pt 控制栏 + 28pt 边距（真实代码如此），快门条还吃 100pt 高度
                avail_w = d["h"] - d["ls"] * 2 - 250 - 28
                avail_h = d["w"] - d["lb"] - SHUTTER_BAR - TOP_BAR - 28
                bottom_bar = 0
            else:
                # 横屏 + 快门浮层：快门条不再占布局高度（系统相机的做法）
                avail_w = d["h"] - d["ls"] * 2
                avail_h = d["w"] - d["lb"]
                bottom_bar = 0
            p = plan(avail_w, avail_h, mode != "portrait", aspect, bottom_bar)
            print(f"{name:<20}{label:<26}{avail_w:>6.0f}×{avail_h:<7.0f}"
                  f"{p['pw']:>6.0f}×{p['ph']:<7.0f}{p['overflow']:>8.1f}{p['fill'] * 100:>7.1f}%")
        print("-" * 92)


if __name__ == "__main__":
    main()
