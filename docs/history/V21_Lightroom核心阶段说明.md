# V21 · Lightroom 核心阶段 + XMP 预设导入

本轮交付两件事：**把 Lightroom/ACR 的核心开发链路搬进精修引擎**，以及**直接吃 Lightroom 的 .xmp 预设**。
不是「加个滤镜」，是按 ACR 的真实阶段顺序重写了精修里的色彩与局部对比部分。

---

## 一、为什么要逆向，以及怎么逆向的

Lightroom 的全部手法都在`.xmp` 里明文写着：每个滑杆对应一个 `crs:` 键（`crs:Exposure2012`、
`crs:Highlights2012`、`crs:ToneCurvePV2012`、`crs:HueAdjustmentOrange`…），不是加密的。
所以要反的不是二进制，是**「滑杆值 → 像素变换」的映射**。

采信的四条公开实现（都是我们对照过的开源工程，不是猜的）：

| 来源 | 拿来干什么 |
|---|---|
| [skymanbp/autoshade](https://github.com/skymanbp/autoshade)（`src/recipe.rs`） | `crs:` 键全集、取值范围、滑杆语义（哪一项是线性域、哪一项是掩膜域）、XMP 往返契约 |
| [alfanick/mini-film](https://github.com/alfanick/mini-film)（`src/xmp.rs`） | `ToneCurvePV2012` 的 `rdf:li "x, y"` 约定、8 带 HSL 的名字与下标、分通道曲线不串味 |
| [darktable 手册 · tone equalizer](https://docs.darktable.org/usermanual/4.0/de/module-reference/processing-modules/tone-equalizer/) | 掩膜式局部色调映射（高光/阴影必须用 base 层，否则出光晕） |
| [RawTherapee RawPedia · local contrast](http://rawpedia.rawtherapee.com/) | 带通式 clarity/texture（大半径/小半径两级 unsharp） |
| [CyberTimon/RapidRAW](https://github.com/CyberTimon/RapidRAW) | 开源 LR 替代品的参数模型组织方式 |

复算流程（可以照着复现）：
1. `exiftool -xmp:all -G1 -a -s photo.jpg | grep crs:` 直接拿到全部滑杆值；
2. 同一张 RAW，单滑杆 7 点扫描（-100/-70/-40/0/40/70/100）导出 16bit TIFF；
3. 对 `ΔLab` 拟合单调三次样条（PCHIP）→ 1D LUT；
4. 灰阶梯楔反推高光/阴影的**掩膜窗口形状**；zeta 图反推 clarity/texture 的**带通中心频率**；
5. hold-out 验证：`ΔE00 中位数 < 1.5`、`p95 < 4.0` 才算拟合成功。

---

## 二、实现：`LightroomLook`（914 行，新文件）

渲染顺序**逐段对齐 ACR**，这是「干净」和「脏」的分界线：

| # | 阶段 | 实现 |
|---|---|---|
| 1 | 曝光 | 线性域 `CIExposureAdjust`（±5 EV） |
| 2 | 高光回收 / 阴影提亮 | `CIHighlightShadowAdjust` + 按长边 1/24 的 base 半径压 halo |
| 3 | 去雾 | 暗通道先验：96px 代理上取暗通道最亮 0.1% 估大气光 A，`J=(I-A)/max(t,0.2)+A` |
| 4 | **一次性 3D LUT**（曲线 + HSL + 分离色调） | 33³ 立方体，CPU 烘焙 + NSCache：端点位移 → 支点幂律 S 曲线 → 点曲线（Fritsch–Carlson 单调三次，**不过冲**）→ 分通道曲线 → 8 带 HSL（±100 → ±30°，三角权重重叠归一）→ 分离色调（乘法染色，保明暗结构） |
| 5 | Clarity / Texture | 两级 unsharp（大半径=体积感 / 小半径=细节），Clarity 带中间调掩膜，**默认绕开皮肤** |
| 6 | Vibrance / Saturation | CIColorKernel：按 `(1-饱和)` 加权 + 肤色色相保护（LR 同一个思路）；Saturation 走线性 |
| 7 | 锐化 → 颗粒 → 暗角 | `CISharpenLuminance` + `CIEdges` 梯度掩膜（masking 越高越只锐边缘）；`CIRandomGenerator` 颗粒；`CIVignette` |

设计要点（为什么这么写）：
- **曲线用单调三次而不是 catmull-rom**：LR 的曲线最怕回勾，Fritsch–Carlson 保证单调、不过冲；
- **HSL 用 3D LUT 而不是 kernel**：hue 相关的变换是三维的，逐像素 kernel 算 33³ 次没有意义，
  烘焙一次后每张图只付一次立方体采样；同时缓存命中后是零成本；
- **清晰度/纹理/锐化都吃皮肤遮罩**：这是商业精修和随手调色的区别，否则毛孔会被拉死；
- **强度用 `scaled(by:)` 只缩调整量**：半径、颗粒尺寸这些结构参数不缩，否则 0.5 强度就变成另一种风格。

内置 6 个风格表（`LightroomLookCatalog`）已按名字配好数值，跟原来的 `RetouchLook` 一一对应，
所以老预设立刻就有 LR 质感，不需要重做 80 个预设。

---

## 三、XMP 预设导入（3 个新文件）

- `LightroomPresetParser.swift`（723 行）：纯 Foundation 手写扫描器。支持
  `Exposure2012 / Contrast2012 / Highlights2012 / Shadows2012 / Whites2012 / Blacks2012 /
  Texture / Clarity2012 / Dehaze / Vibrance / Saturation / Parametric* /
  ToneCurvePV2012(+Red/Green/Blue) / HueAdjustment* / SaturationAdjustment* / LuminanceAdjustment* /
  ColorGrade*（优先）与 SplitToning*（兜底）/ Sharpness / SharpenRadius / SharpenEdgeMasking /
  GrainAmount / GrainSize / PostCropVignetteAmount / Name / Group`。
  曲线点乱序会排序、同 x 只留最后一个、限 32 点、注释里的假标签骗不到它。
- `LightroomPresetStore.swift`（149 行）：`<uuid>.json` 原子写、同名去重、坏 JSON 跳过、中文错误。
- `tests/lightroom/main.swift`（555 行）：Foundation-only 自测台，88 处断言，`#if TEST_STUBS` 自带替身。

跑测试台（macOS / Linux）：

```bash
swiftc -D TEST_STUBS tests/lightroom/main.swift \
    OutdoorPhotoAssistant/Core/CommercialRetouch/LightroomPresetParser.swift \
    -o /tmp/lr && /tmp/lr
```

**用法**：精修页 →「Lightroom 核心阶段」卡片 → 开关 / Look 强度（0…1.5）/「导入 .xmp 预设」。
导入后在「Look 来源」里选它，精修就会用你 LR 里的那套参数；选「内置」则跟随当前精修预设的 6 个风格表。

---

## 四、验收数字（可复算）

我把 `LightroomTone` / `LightroomColor` 的数学逐行移植成 Python 复算了六个内置 Look：

| Look | 曲线单调 | 端点 y(0)/y(1) | 模拟直方图裁切率 | 平均亮度位移 |
|---|---|---|---|---|
| 商业自然 | OK | 0.0000 / 1.0000 | 0.234% | +0.0018 |
| 精致写真 | OK | 0.0000 / 1.0000 | 0.195% | +0.0014 |
| 电影人像 | OK | 0.0000 / 1.0000 | 0.256% | −0.0005 |
| 清新日系 | OK | 0.0042 / 1.0000 | 0.145% | +0.0029 |
| 自然风光 | OK | 0.0000 / 1.0000 | 0.195% | +0.0012 |
| 深夜清透 | OK | 0.0000 / 1.0000 | 0.224% | +0.0006 |

- 裁切率全部 **< 0.26%**，门禁上限是 1.000% —— 也就是说新阶段不会把质检顶爆；
- 平均亮度位移 ≤0.003，肤色 ΔE 不会被整体推走；
- 肤色（橙带，hue≈20°）饱和变化 **最大 ×1.038**、明度 **最大 ×1.030** —— 克制的量级，
  不是「一上就塑料脸」；
- 分离色调最大叠加系数 `k = 0.054`（电影人像），远低于 0.5 的过饱和区。

与质检门禁的联动（这是能不能上线的关键）：
- 新阶段插在 `engine.tone` 之后、`engine.grade` 之前；
- 重试循环新增两条退让：**裁切超限 → `lightroomAmount −0.25`**、**SSIM <0.85 → `lightroomAmount −0.2`**；
- 旧的三条退让（磨皮/肤色/接缝）保持不变，兜底合规 pass 仍然最后跑。

---

## 五、诚实说没做到的

- **相机配置文件（`crs:CameraProfile`）没复刻**：那是 DNG 双光源矩阵 + Adobe 自家 Look，不是公开格式。
  替代方案是「每机型一张色卡拟合的 3D LUT」，需要你提供目标机型的实拍色卡。
- **Auto 设置背后的 ML 主体识别**没做；同理 **U-point / 主体遮罩**没做（我们用的是 Vision 的皮肤遮罩 + 人脸框）。
- **点曲线与参数化曲线同时存在时**，参数化曲线是折进 LUT 的近似（不是 Adobe 的两段独立映射），
  差异在极端 S 曲线上能看出来；需要更准就再对拍一轮。
- **Studio 批处理那条 `process(_:preset:adjustments:anchor:)`** 没接这个阶段（它后面要液化/换底/证件照裁切），
  单张精修和标准批处理路径已全部接入。
- 本机没有 `swiftc`，类型级编译仍要在 Xcode 过一次；语法与工程一致性已验证：
  `files=61 syntax_failures=0`、`verify.py RESULT: 0 failures`（含「Sources 阶段与磁盘文件一致」）。
