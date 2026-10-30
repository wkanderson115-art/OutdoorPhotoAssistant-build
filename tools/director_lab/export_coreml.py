"""把训练好的 DirectorNet 转成 Core ML（mlprogram，iOS 17+）。

    python -m tools.director_lab.export_coreml --ckpt runs/v1/best.pt --out DirectorNet.mlpackage

在 macOS 上会额外用 Core ML 跑一次预测，与 PyTorch 结果比对。
"""
from __future__ import annotations

import argparse
import platform
from pathlib import Path

import numpy as np
import torch
import coremltools as ct

from . import geometry as g
from .model import DirectorNet


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=Path("DirectorNet.mlpackage"))
    args = ap.parse_args()

    ckpt = torch.load(args.ckpt, map_location="cpu")
    smoke = bool(ckpt.get("smoke"))
    model = DirectorNet(pretrained=False)
    model.load_state_dict(ckpt["state"])
    model.eval()

    example_image = torch.rand(1, 3, 224, 224)
    example_aspect = torch.tensor([[0.75]])
    traced = torch.jit.trace(model, (example_image, example_aspect))

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1 / 255.0,
                         color_layout=ct.colorlayout.RGB),
            ct.TensorType(name="aspect", shape=(1, 1), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="scene"), ct.TensorType(name="quality"), ct.TensorType(name="shift")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "户外拍照助手 AI 导演：场景分类 + 构图质量 + 取景调整建议"
    mlmodel.user_defined_metadata["labels"] = ",".join(g.SCENES)
    mlmodel.user_defined_metadata["stage"] = "smoke" if smoke else "trained"
    mlmodel.user_defined_metadata["shift_convention"] = "dx>0 机位右移; dy>0 机位下移; dz>0 推近"
    mlmodel.save(str(args.out))
    print("已保存", args.out, "(stage=%s)" % ("smoke" if smoke else "trained"))

    if platform.system() == "Darwin":
        from PIL import Image
        rng = np.random.default_rng(0)
        arr = (rng.random((224, 224, 3)) * 255).astype("uint8")
        with torch.no_grad():
            ref = model(torch.from_numpy(arr).permute(2, 0, 1)[None].float() / 255.0, example_aspect)
        out = mlmodel.predict({"image": Image.fromarray(arr), "aspect": np.array([[0.75]], dtype=np.float32)})
        diff = max(float(np.abs(np.array(out["shift"]).reshape(-1) - ref[2].numpy().reshape(-1)).max()),
                   float(np.abs(np.array(out["quality"]).reshape(-1) - ref[1].numpy().reshape(-1)).max()))
        print("PyTorch 与 Core ML 最大差异：%.4f（FP16，<0.02 正常）" % diff)
    else:
        print("提示：非 macOS 无法在此验证 Core ML 预测，请在 Mac 上再跑一次本脚本做比对。")


if __name__ == "__main__":
    main()
