"""训练 DirectorNet。

    python -m tools.director_lab.train_director --data /path/to/data --epochs 20 --out runs/v1
    python -m tools.director_lab.train_director --smoke --epochs 1 --out runs/smoke   # 只验证管线

输出  <out>/best.pt  与  <out>/metrics.json
"""
from __future__ import annotations

import argparse
import json
import math
import tempfile
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from . import geometry as g
from .dataset import DirectorDataset, list_images, load_crops, make_smoke_dataset, split
from .model import DirectorNet


def pick_device():
    if torch.cuda.is_available():
        return torch.device("cuda")
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def compute_loss(outputs, batch, w_scene=1.0, w_quality=2.0, w_shift=4.0):
    logits_s, logits_q, shift = outputs
    _, aspect, scene, q, target = batch
    loss_scene = torch.zeros((), device=shift.device)
    mask = scene >= 0
    if mask.any():
        loss_scene = F.cross_entropy(logits_s[mask], scene[mask], label_smoothing=0.05)
    loss_q = F.binary_cross_entropy_with_logits(logits_q, q)
    loss_shift = F.smooth_l1_loss(torch.tanh(shift), target, beta=0.1)
    return w_scene * loss_scene + w_quality * loss_q + w_shift * loss_shift


@torch.no_grad()
def evaluate(model, loader, device):
    model.eval()
    n = correct = labeled = 0
    q_err = shift_err = zero_err = 0.0
    for batch in loader:
        image, aspect, scene, q, target = [t.to(device) for t in batch]
        probs, qp, sp = model(image, aspect)
        n += image.shape[0]
        mask = scene >= 0
        labeled += int(mask.sum())
        correct += int((probs.argmax(1)[mask] == scene[mask]).sum())
        q_err += float((qp - q).abs().sum())
        shift_err += float((sp - target).abs().mean(1).sum())
        zero_err += float(target.abs().mean(1).sum())   # 「永远建议不动」基线
    return {
        "scene_acc": correct / max(1, labeled) if labeled else None,
        "quality_mae": q_err / max(1, n),
        "shift_mae": shift_err / max(1, n),
        "shift_mae_zero_baseline": zero_err / max(1, n),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--smoke", action="store_true", help="用合成图片验证管线，模型不可用于拍摄")
    ap.add_argument("--no-pretrained", action="store_true", help="不下载 ImageNet 预训练权重（离线调试用）")
    args = ap.parse_args()

    tmp = None
    if args.smoke:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        make_smoke_dataset(root)
        args.workers = 0
    else:
        if not args.data or not args.data.is_dir():
            ap.error("需要 --data 指向图片目录（或使用 --smoke）")
        root = args.data

    items = list_images(root)
    if len(items) < 20:
        raise SystemExit(f"图片太少：{len(items)} 张")
    crops = load_crops(root)
    train_items, val_items = split(items)
    print(f"图片 {len(items)}（训练 {len(train_items)} / 验证 {len(val_items)}），"
          f"带场景标签 {sum(1 for _, s in items if s >= 0)}，带裁剪标注 {len(crops)}")

    device = pick_device()
    print("device:", device)
    model = DirectorNet(pretrained=not (args.smoke or args.no_pretrained)).to(device)
    train_loader = DataLoader(DirectorDataset(root, train_items, crops, True), batch_size=args.batch,
                              shuffle=True, num_workers=args.workers, drop_last=len(train_items) > args.batch)
    val_loader = DataLoader(DirectorDataset(root, val_items, crops, False), batch_size=args.batch,
                            num_workers=args.workers)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    steps = max(1, args.epochs * len(train_loader))
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=steps)

    args.out.mkdir(parents=True, exist_ok=True)
    best, history = math.inf, []
    for epoch in range(args.epochs):
        model.train()
        running = 0.0
        for batch in train_loader:
            batch = [t.to(device) for t in batch]
            outputs = model.forward_logits(batch[0], batch[1])
            loss = compute_loss(outputs, batch)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step(); sched.step()
            running += float(loss)
        metrics = evaluate(model, val_loader, device)
        metrics.update(epoch=epoch + 1, train_loss=running / max(1, len(train_loader)))
        history.append(metrics)
        print(json.dumps(metrics, ensure_ascii=False))
        score = metrics["shift_mae"] + metrics["quality_mae"] - (metrics["scene_acc"] or 0)
        if score < best:
            best = score
            torch.save({"state": model.state_dict(), "scenes": g.SCENES, "smoke": args.smoke}, args.out / "best.pt")
    (args.out / "metrics.json").write_text(json.dumps(history, ensure_ascii=False, indent=2), encoding="utf-8")
    print("完成：", args.out / "best.pt")
    if tmp:
        tmp.cleanup()


if __name__ == "__main__":
    main()
