# V18 魔法第三级（第一阶）· 学习型瑕疵判别器

## 0. 结论

第三级的「数据 + 模型」这一阶做完了，而且是**真的训练出来、真的过验证**的，不是占位：

| 指标 | 训练集 | **留出验证集** |
| --- | --- | --- |
| 精确率 precision | 0.9948 | **1.0000** |
| 召回率 recall | 0.9847 | **0.9518** |
| F1 | 0.9897 | **0.9753** |
| 正/负平均分 | 0.963 / 0.017 | **0.939 / 0.017** |

数据规模：879 个样本（279 个注入瑕疵 / 600 个干净皮肤点），来自真实人像皮肤纹理经 4 档 gamma（0.90/1.00/1.10/1.20）增广；训练/验证 70/30 分层随机划分。模型只有 9 个特征 + 10 个参数，可解释、可复现、无依赖。

## 1. 为什么是这个形态（而不是 CoreML 分割网）

- 完整分割网需要 500–2000 对手工标注的「精修前/后」图和 GPU，本机两者都没有。硬凑出来的模型不能信，交给你就是埋雷。
- 真正能诚实训练的，是**候选之后的判别**：候选生成保持经典的尺度归一化 LoG（和生产代码一致），模型只负责把「真瑕疵」从「雀斑 / 毛孔 / 睫毛 / 阴影台阶」里挑出来——这恰好是手写阈值最不擅长的一段。
- 结果：9 个特征、10 个参数、纯浮点运算，直接内联进 Swift，**不需要模型文件、不需要 CoreML、不需要 Metal**，也不会因为系统版本变化而行为漂移。

## 2. 特征（Swift 端与训练脚本完全一致）

顺序：`dL, dA, dB, log1, log2, log3, grad, ringStd, dE`

- `dL/dA/dB`：中心像素相对周围（σ = 0.05×脸宽）的 Lab 偏差
- `log1..3`：σ = 0.004 / 0.006 / 0.009 × 脸宽的尺度归一化 LoG 响应
- `grad`：平滑亮度梯度（排除边缘/睫毛）
- `ringStd`：外环亮度标准差（区分「斑点」与「纹理区」）
- `dE`：中心与周围的 CIEDE2000

## 3. 产物

| 文件 | 说明 |
| --- | --- |
| `tools/model_lab/train_blemish.py` | 数据合成 + 增广 + 训练 + 留出评估 + 导出，一条命令跑完（`python -m tools.model_lab.train_blemish`） |
| `OutdoorPhotoAssistant/Core/CommercialRetouch/BlemishLearnedModel.swift` | 生成的打分器：权重/均值/尺度/偏置 + `probability(_:)` / `isBlemish(_:)` |
| `OutdoorPhotoAssistant/Core/CommercialRetouch/BlemishModelBridge.swift` | 与经典检测器的桥：`rescore(_:features:)` + 给质检面板的中文摘要；**纯新增文件，不改动既有引擎**，所以零回归风险 |
| `acceptance/blemish_model.json` | 权重与全部指标（可复算） |

桥接的接入点是 `RetouchEngine.detectSpots` 里已有候选集的那一行，改动量 1 行：

```swift
detection.spots = BlemishModelBridge.rescore(detection.spots, features: detection.featureRows)
```

之所以这轮**没有直接改引擎**：没有编译器的情况下改热路径是唯一可能把「绿」变「红」的操作。桥接文件本身可独立编译（只 import Foundation），第一次 Xcode 构建通过后，这一行再接。

## 4. 跑绿清单（本机实测）

| 检查 | 结果 |
| --- | --- |
| `python -m tools.model_lab.train_blemish` | **PASS**（留出 precision 1.000 / recall 0.952） |
| `python -m tools.retouch_lab.verify_studio` | PASS（套系一致性 0.517 ΔE、液化不变量、证件照几何） |
| `python tools/retouch_lab/run.py`（人像验收） | PASS（纹理 1.053、肤色 ΔE 1.21、新增裁切 0、SSIM 0.977） |
| `python scripts/check_retouch_sources.py` | **0 问题**（3 个目录、全部 Swift 文件） |
| `scripts/gen_pbxproj.py` | 已重新生成，CommercialRetouch 20 个文件 + Cloud 4 个 + Features 2 个全部进 Sources phase |

## 5. 第三级还剩什么（诚实边界）

1. **真正的分割网**：需要 500–2000 对人工精修样本（你手上客片即可）+ 一台带 GPU 的机器，训练完用 `coremltools` 导出；那时把 `BlemishModelBridge` 换成模型推理即可，接口不用改。
2. **硬负样本**：现在的负样本是干净皮肤点；下一轮要加入「雀斑 / 痣 / 胡茬 / 睫毛 / 高光点」，模型才会真正学会「哪些不该修」。这是最便宜的一次提升（数据脚本已支持，只需补采样）。
3. **真机帧率**：9 个特征在代理图上算，单张 <10 ms 量级，但没有真机数据，不写结论。
