# AI 导演模型（Core ML）

App 里的 `DirectorMLModel.swift` 会加载 `DirectorNet`，没有这个模型时自动退回规则导演，所以**不放模型也能正常编译运行**。

## 模型做什么

输入一帧画面（224×224）和画面宽高比，输出三样东西：

| 输出 | 含义 |
| --- | --- |
| `scene` | 场景概率：人物 / 风景 / 海边 / 日落 / 夜景 / 建筑 / 花草 / 汽车 |
| `quality` | 0–1，当前取景离「理想取景」有多近 |
| `shift` | `dx, dy, dz`：相机该往右(+)/下(+)移多少、推近(+)/拉远(−)多少（单位见 `geometry.py`） |

宽高比作为输入，所以同一个模型横屏、竖屏都能用。

App 怎么用它：场景分类修正 Vision 的关键词判断（人物仍以 Vision 检测为准）；`quality`/`shift` 变成屏幕上的移动提示；`quality` 过低时暂缓自动快门。**模型不会直接控制镜头变焦**，变焦仍走原来的主体门控和冷却。

## 训练

```bash
pip install -r tools/director_lab/requirements.txt          # 在项目根目录执行

# 1) 先用合成图片验证整条管线（几分钟，模型没有实际价值，App 会拒绝加载）
python -m tools.director_lab.train_director --smoke --epochs 1 --out runs/smoke
python -m tools.director_lab.export_coreml --ckpt runs/smoke/best.pt --out DirectorNet_smoke.mlpackage

# 2) 真正训练
python -m tools.director_lab.train_director --data /path/to/data --epochs 20 --out runs/v1
python -m tools.director_lab.export_coreml --ckpt runs/v1/best.pt --out DirectorNet.mlpackage
```

训练脚本需要 PyTorch，建议在有 GPU 的机器或 Apple Silicon（MPS）上跑；转换必须在装有 `coremltools` 的环境里做，在 Mac 上转换还会自动对比 PyTorch 与 Core ML 的输出。

## 数据怎么放

```
data/
  人物/ 风景/ 海边/ 日落/ 夜景/ 建筑/ 花草/ 汽车/   ← 目录名属于上面 8 类，图片带场景标签
  其他任意目录/                                     ← 没有场景标签，只学构图
  crops.csv                                         ← 可选：rel_path,x,y,w,h（最佳裁剪框，0–1 归一化）
```

构图（`quality`/`shift`）有两种学法，可以混用：

1. **自监督（默认）**：把图片本身的取景当作「理想取景」，随机裁出更小、偏一点的窗口当输入，目标是「该怎么动才能回到原图取景」。只需要一批构图好的照片，不用人工标注。**局限**：模型只见过「取得太紧、偏了」，所以主要学会「拉远 / 平移」，学不到「太松了要推近」。
2. **带最佳裁剪框标注**：提供 `crops.csv`（可由 GAIC、CPC、FCDB 等裁剪数据集转换而来），模型就能学到「推近」。想让 AI 导演也会说「再靠近一点」，需要这类数据。

**数据许可**：公开数据集的使用条款各不相同，很多限制商用。如果这个 App 要上架或收费，请逐个确认许可，或者用自己拍的、有授权的照片。

## 评估看什么

训练日志每轮输出：

* `scene_acc`：场景准确率；
* `quality_mae`：质量分误差；
* `shift_mae` 和 `shift_mae_zero_baseline`：**`shift_mae` 必须明显低于零基线**（「永远建议不动」的误差），否则模型没学到东西。

指标好只说明它学会了你给的数据，**实际拍起来准不准、会不会发热掉帧，要装到真机上看**。

## 放进 App

1. 把导出的 `DirectorNet.mlpackage` 拖进 Xcode 工程（勾选 `OutdoorPhotoAssistant` target）；Xcode 会把它编译成 `DirectorNet.mlmodelc` 打进包里。
2. 运行 App，`DirectorMLModel.shared.statusText` 会说明加载状态（未内置 / 已加载 / 管线测试模型被忽略 / 加载失败）。
3. 改场景列表时，`geometry.py` 的 `SCENES`、`DirectorMLModel.fallbackLabels` 要一起改（模型元数据里也带了 labels，App 优先读元数据）。

## 测试

```bash
python -m unittest tools.director_lab.test_geometry -v    # 取景几何和训练目标，不需要 torch
```
