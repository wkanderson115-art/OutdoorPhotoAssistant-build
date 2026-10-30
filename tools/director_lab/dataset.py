"""数据集：目录结构见 README.md。

data_root/
  人物/ 风景/ 海边/ ... (名字属于 SCENES 的子目录 -> 带场景标签)
  其他任意名字/       (没有场景标签，只参与取景/构图学习)
  crops.csv           (可选) rel_path,x,y,w,h  最佳裁剪框，归一化坐标
"""
from __future__ import annotations

import csv
import hashlib
import random
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from PIL import Image, ImageEnhance
import torch
from torch.utils.data import Dataset

from . import geometry as g

IMG_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
INPUT_SIZE = 224


def list_images(root: Path) -> List[Tuple[Path, int]]:
    items: List[Tuple[Path, int]] = []
    for p in sorted(root.rglob("*")):
        if p.suffix.lower() in IMG_EXT:
            rel = p.relative_to(root)
            top = rel.parts[0] if len(rel.parts) > 1 else None
            items.append((p, g.scene_index(top)))
    return items


def load_crops(root: Path) -> Dict[str, g.Window]:
    path = root / "crops.csv"
    out: Dict[str, g.Window] = {}
    if not path.exists():
        return out
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            x, y, w, h = (float(row[k]) for k in ("x", "y", "w", "h"))
            if w > 0.05 and h > 0.05 and 0 <= x < 1 and 0 <= y < 1 and x + w <= 1.001 and y + h <= 1.001:
                out[row["rel_path"].replace("\\", "/")] = g.ideal_from_box(x, y, w, h)
    return out


def split(items, val_fraction: float = 0.1):
    """按文件名哈希切分，保证每次运行验证集不变。"""
    train, val = [], []
    for item in items:
        h = int(hashlib.md5(item[0].name.encode("utf-8")).hexdigest(), 16) % 1000
        (val if h < val_fraction * 1000 else train).append(item)
    return train, val


class DirectorDataset(Dataset):
    def __init__(self, root: Path, items, crops: Dict[str, g.Window], train: bool, seed: int = 0):
        self.root, self.items, self.crops, self.train = root, items, crops, train
        self.seed = seed

    def __len__(self):
        return len(self.items)

    def __getitem__(self, idx):
        path, scene = self.items[idx]
        # 验证集用固定随机数，保证指标可比较；训练集每次随机
        rng = random.Random(self.seed * 1_000_003 + idx) if not self.train else random.Random()
        img = Image.open(path).convert("RGB")
        rel = path.relative_to(self.root).as_posix()
        ideal = self.crops.get(rel, g.full_image_ideal())
        if self.train and rng.random() < 0.5:
            img = img.transpose(Image.FLIP_LEFT_RIGHT)
            ideal = g.flip_horizontal(ideal)
        cur = g.sample_current_window(ideal, rng)
        dx, dy, dz, q = g.make_target(cur, ideal)

        W, H = img.size
        x0, y0, bw, bh = cur.box()
        crop = img.crop((round(x0 * W), round(y0 * H), round((x0 + bw) * W), round((y0 + bh) * H)))
        aspect = W / max(1, H)          # 窗口与原图同宽高比
        crop = crop.resize((INPUT_SIZE, INPUT_SIZE), Image.BILINEAR)
        if self.train:
            crop = ImageEnhance.Brightness(crop).enhance(rng.uniform(0.8, 1.2))
            crop = ImageEnhance.Contrast(crop).enhance(rng.uniform(0.85, 1.15))
        arr = torch.from_numpy(__import__("numpy").asarray(crop, dtype="float32") / 255.0).permute(2, 0, 1)
        return (arr, torch.tensor([aspect], dtype=torch.float32),
                torch.tensor(scene, dtype=torch.long),
                torch.tensor([q], dtype=torch.float32),
                torch.tensor([dx, dy, dz], dtype=torch.float32))


def make_smoke_dataset(root: Path, n_per_scene: int = 12, seed: int = 0):
    """生成纯合成图片，只用来验证「训练 -> 转换 -> App 加载」管线能跑通。

    用它训练出来的模型没有任何拍摄价值，导出时会被标记为 stage=smoke，App 会拒绝使用。
    """
    from PIL import ImageDraw
    rng = random.Random(seed)
    for scene in g.SCENES:
        d = root / scene
        d.mkdir(parents=True, exist_ok=True)
        for i in range(n_per_scene):
            w, h = rng.choice([(320, 240), (240, 320), (360, 240)])
            img = Image.new("RGB", (w, h), tuple(rng.randint(30, 220) for _ in range(3)))
            draw = ImageDraw.Draw(img)
            for _ in range(4):
                x, y = rng.randint(0, w - 40), rng.randint(0, h - 40)
                draw.ellipse((x, y, x + rng.randint(20, 90), y + rng.randint(20, 90)),
                             fill=tuple(rng.randint(0, 255) for _ in range(3)))
            img.save(d / f"{scene}_{i:03d}.jpg", quality=90)
