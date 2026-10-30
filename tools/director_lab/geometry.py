"""取景窗口几何与训练目标（不依赖 torch，可单独测试）。

约定
----
* 所有坐标都是相对原图的归一化坐标，x 向右、y 向下。
* 「取景窗口」与原图保持同一宽高比，因此只需要 (cx, cy, s)：
  中心点和边长占原图宽/高的比例，窗口 = (cx - s/2, cy - s/2, s, s)（归一化）。
* 模型输出 shift = (dx, dy, dz)，含义是「相机应该怎么动，才能到理想取景」：
    dx > 0  机位向右移 / 向右转，幅度 = dx × 当前画面宽度
    dy > 0  机位向下移 / 向下转，幅度 = dy × 当前画面高度
    dz > 0  推近（zoom in），倍率变化 = exp(dz)；dz < 0 拉远
  因此 App 端得到 dx 时，主体应该「在画面里向左移动」。
* quality ∈ [0, 1]：当前取景与理想取景的接近程度（1 = 已经就是理想取景）。
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass
from typing import Optional, Tuple

SCENES = ["人物", "风景", "海边", "日落", "夜景", "建筑", "花草", "汽车"]

SHIFT_LIMIT = 1.0     # dx/dy/dz 训练目标裁剪范围
QUALITY_K_POS = 1.6   # 平移误差对 quality 的衰减系数
QUALITY_K_ZOOM = 1.2  # 缩放误差对 quality 的衰减系数


@dataclass(frozen=True)
class Window:
    cx: float
    cy: float
    s: float

    def box(self) -> Tuple[float, float, float, float]:
        return (self.cx - self.s / 2, self.cy - self.s / 2, self.s, self.s)


def clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def window_inside(cx: float, cy: float, s: float) -> Window:
    """把窗口平移到图内（s 先限制在 (0, 1]）。"""
    s = clamp(s, 0.05, 1.0)
    return Window(clamp(cx, s / 2, 1 - s / 2), clamp(cy, s / 2, 1 - s / 2), s)


def ideal_from_box(x: float, y: float, w: float, h: float) -> Window:
    """标注的最佳裁剪框（宽高比可以与原图不同）-> 理想窗口。

    边长用几何平均 sqrt(w*h)，保证面积一致；中心保持不变。
    """
    return Window(x + w / 2, y + h / 2, math.sqrt(max(1e-6, w * h)))


def full_image_ideal() -> Window:
    return Window(0.5, 0.5, 1.0)


def make_target(current: Window, ideal: Window) -> Tuple[float, float, float, float]:
    """返回 (dx, dy, dz, quality)。"""
    dx = (ideal.cx - current.cx) / current.s
    dy = (ideal.cy - current.cy) / current.s
    dz = math.log(current.s / ideal.s)
    dx = clamp(dx, -SHIFT_LIMIT, SHIFT_LIMIT)
    dy = clamp(dy, -SHIFT_LIMIT, SHIFT_LIMIT)
    dz = clamp(dz, -SHIFT_LIMIT, SHIFT_LIMIT)
    q = math.exp(-(QUALITY_K_POS * (abs(dx) + abs(dy)) + QUALITY_K_ZOOM * abs(dz)))
    return dx, dy, dz, clamp(q, 0.0, 1.0)


def apply_shift(current: Window, dx: float, dy: float, dz: float) -> Window:
    """按模型输出移动窗口（用于验证 / 可视化）。"""
    return window_inside(current.cx + dx * current.s, current.cy + dy * current.s, current.s * math.exp(-dz))


def _overlap_ratio(a: Window, b: Window) -> float:
    ax, ay, aw, ah = a.box()
    bx, by, bw, bh = b.box()
    iw = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    ih = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    return (iw * ih) / max(1e-9, bw * bh)  # 相对 b（理想窗口）面积


def sample_current_window(ideal: Window, rng: random.Random, *,
                          keep_prob: float = 0.2,
                          min_scale: float = 0.45,
                          min_overlap: float = 0.6) -> Window:
    """围绕理想窗口随机采样一个「当前取景」。

    * keep_prob 的概率直接取理想窗口（对应 quality = 1，让模型学会「别乱动」）；
    * 其余随机缩放+平移，并要求仍覆盖理想窗口至少 min_overlap（否则从像素里根本看不到该往哪走）。
    """
    if rng.random() < keep_prob:
        return window_inside(ideal.cx, ideal.cy, ideal.s)
    for _ in range(40):
        s = rng.uniform(min_scale, 1.0)
        s = min(s, 1.0)
        lim = (1 - s) / 2
        cx = 0.5 + rng.uniform(-lim, lim) if lim > 0 else 0.5
        cy = 0.5 + rng.uniform(-lim, lim) if lim > 0 else 0.5
        w = Window(cx, cy, s)
        if _overlap_ratio(w, ideal) >= min_overlap:
            return w
    return window_inside(ideal.cx, ideal.cy, ideal.s)


def flip_horizontal(w: Window) -> Window:
    return Window(1 - w.cx, w.cy, w.s)


def scene_index(name: Optional[str]) -> int:
    """场景名 -> 下标；没有标签返回 -1（训练时该样本不计场景损失）。"""
    if name in SCENES:
        return SCENES.index(name)
    return -1
