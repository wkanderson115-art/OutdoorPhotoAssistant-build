# ACR Develop 引擎复刻说明（Camera Raw 18.7）

> 这一版把 Camera Raw / Lightroom 的 Develop 管线**按逆向结果逐段重写**，替换掉原来那套
> "CIHighlightShadowAdjust + CIUnsharpMask + 单点去雾"的近似实现。旧的近似做法有三个硬伤：
> 高光/阴影用 Apple 的局部色调映射（不是 ACR 的算法）、Clarity/Texture 都是 USM（所以会出白边）、
> 去雾只有一次 `(I-A)/t+A` 没有透射图细化（所以灰蒙蒙）。

---

## 1. 逆向依据（数据来源）

目标：`C:\Program Files\Common Files\Adobe\Plug-Ins\CC\File Formats\Camera Raw.8bi`
（Camera Raw **18.7**，245,288,936 字节，MD5 `EF8C6AE58B1C99ECDCDB6715A941A1E7`，未加壳，PDB 未剥离）

| 证据 | 数量 | 用途 |
|---|---|---|
| RTTI 类名 | 7,904 个 | 其中 **358 个 `cr_stage_*`** = Develop 的完整算子表 |
| DXBC 着色器 | 294 个 | 精修算子的 GPU 实现 |
| 常量缓冲结构 | 143 个 `Uniforms*` | 每个算子的参数结构 |
| 着色器绑定名 | 1,802 个 | 参数级线索（`clarityAmount`、`f_ay_inv`、`fEpsY`…） |

关键证据 → 结论：

| 结论 | 证据 |
|---|---|
| Clarity 是 Y 通道局部对比 | `cr_stage_LocalContrastY`、`UniformsLocalContrast`、`clarityAmount` |
| Texture 是 YCC 直接引导滤波 | `cr_stage_texture_direct_gf_ycc`、`dstTex_ab*`、`fEpsY/fEpsC1/fEpsC2` |
| 去雾是暗通道先验 + 引导滤波细化 | `cr_stage_dark_channel`、`UniformsDehazeTrMConstantAirlightData`、`f_ay / f_ay_inv / f_t0 / f_th2_ay_inv` |
| 锐化是三尺度 + 输出级带阈值 USM | `cr_stage_sharpen_3`、`UniformsOutputSharpenUSMWithThreshold`、`fWeights[]`、`threshold` |
| 降噪是金字塔 + 交叉双边 + 秩滤波 | `cr_stage_denoise`、`UniformsDenoisePyramidBuildHp`、`UniformsDenoiseCrossBilateralAcrossOrDown`、`UniformsDenoiseRank3x3PlusHpThreshold` |
| 曲线是逐通道 RGB 曲线 | `UniformsLumaCurve`、`UniformsRGBCurve`、`UniformsRGBTable` |
| HSL 是 8 带 tuner | `cr_stage_HSLTuner`、`UniformsHSLTuner` |
| 整条管线融进 uber-shader | 4 个 116–188 KB 的 DXBC，用 `fHasXxx` 布尔开关裁剪 |
| AI 走 WinML + ONNX + DirectML | `SenseiWinML::SenseiBindingWinML`、176 处 `ONNX` |

---

## 2. 文件清单

| 文件 | 作用 |
|---|---|
| `OutdoorPhotoAssistant/Core/CommercialRetouch/ACRDevelopEngine.swift` | 引擎本体：参数模型 + 14 段管线 + CIKL kernels + 3D LUT 烘焙 + DCP 解析（零 App 依赖，可单独编译测试） |
| `.../ACRDevelopBridge.swift` | `LightroomLook` → `ACRDevelopSettings` 桥接 + `applyWithACREngine` |
| `tests/acrdevelop/main.swift` | 15 组行为断言（曝光/对比/端点/去雾/Clarity/Texture/锐化/降噪/颗粒/暗角/曲线/三级调色/DCP 解析/强度缩放） |
| `tools/acr_parity.py` | Python 侧公式复算 + 手搓 DCP 字节自检，产出 Swift 测试的参考值 |

工程文件 `OutdoorPhotoAssistant.xcodeproj/project.pbxproj` 已加入两个新源文件
（`F…69 / B…69` = 引擎，`F…6A / B…6A` = 桥接），编译阶段与分组都已登记。

---

## 3. 管线（顺序即 ACR 的真实顺序）

| # | 阶段 | Swift 实现 | 域 | 依据 |
|---|---|---|---|---|
| 1 | 白平衡 | `stageWhiteBalance` | 线性 | `cr_stage_white_balance_3` |
| 2 | 相机配置文件 | `stageCameraProfile`（`ACRDCPProfile`） | 线性 | `cr_stage_ABCtoRGB / CameraToRGB` |
| 3 | 曝光 | `K.exposure` | 线性 | `UniformsExposure` |
| 4 | 高光/阴影 | `stageHighlightsShadows`（box base + 亮度差） | 线性 | `cr_stage_local_whites_blacks` |
| 5 | 去雾 | `stageDehaze`（暗通道→大气光→透射图→引导滤波→t0/软阈值） | 线性 | `cr_stage_dehaze` 全参数组 |
| 6 | 黑白端点 | `stageEndpoints` | 显示 | `UniformsLocalWhitesBlacks` |
| 7 | 对比度 | `stageContrast`（pivot + 软 S） | 显示 | `contrastSplit / contrastSplitSlope` |
| 8 | 曲线+参数化+HSL+颜色分级 | `ACRLookCube.data(for:size:)`（33³ LUT） | 显示 | `curve_tone_map / HSLTuner / SplitTone / LocalColorToning` |
| 9 | 亮度/色彩降噪 | `stageNoiseReduction`（引导滤波保边 + YCC 色度平滑） | 显示 | `cr_stage_denoise / pyramid / bilateral` |
| 10 | Clarity | `stageClarity`（Y 上引导滤波分解 + 中间调掩膜） | 显示 | `cr_stage_LocalContrastY` |
| 11 | Texture | `stageTexture`（YCC 三 eps 直接引导滤波） | 显示 | `cr_stage_texture_direct_gf_ycc` |
| 12 | 锐化 | `stageSharpen`（三尺度 USM + 阈值 + CIEdges 掩膜） | 显示 | `cr_stage_sharpen_3 / output_sharpen` |
| 13 | 颗粒 | `stageGrain` | 显示 | `cr_stage_overlay_grain` |
| 14 | 暗角 | `stageVignette`（中点/羽化/圆度） | 显示 | `cr_stage_post_crop_vignette` |

### 3.1 引导滤波的实现方式

CIKL（`CIColorKernel`）拿不到邻域，所以引擎里的
`cr_stage_box_conv_plus_product_and_computeab` + `cr_stage_apply_affine_function`
在这里拆成 **CIBoxBlur × 6 + 3 个 kernel**：

```
mI  = box(I)      mP = box(P)      mII = box(I²)      mIP = box(I·P)
a   = (mIP - mI·mP) / (var + eps)          ← K.gfA
b   = mP - a·mI                            ← K.gfB
q   = box(a)·I + box(b)                    ← K.gfApply
```

`a`、`b` 用 `0.5 + v*0.25` 的偏移编码存进图像，避免中间结果被 Core Image 裁到 `[0,1]` 丢掉负值
（`a∈[0,1]`、`|b|≤1` 时编码值稳定落在 `[0.25,0.75]`，`tools/acr_parity.py` 第 6 节有数值验证）。

### 3.2 去雾的公式与参数映射

```
dark      = min(R,G,B) → CIMorphologyMinimum(radius)              fRadius
A         = 暗通道最亮 0.1% 像素的均值                             ConstantsAirlight
t0        = clamp(1 - omega·dark/A, 0.05, 1)                       omega = 0.92·amount
t         = GuidedFilter(guide=dark, src=t0, eps)                  eps / f_ay_inv
I'        = max(I - th²/A, 0)                                      f_th2_ay_inv
J         = (I' - A)/max(t, t_floor) + A                           f_t0
```

---

## 4. 接入方式

`LightroomLook.apply(to:skinMask:context:)` 的函数体已经换成调用引擎：

```swift
func apply(to image: CIImage, skinMask: CIImage? = nil, context: CIContext) -> CIImage {
    return ACRDevelopEngine.render(image, settings: acrSettings,
                                   skinMask: skinMask, profile: nil, context: context)
}
```

- **调用方零改动**：`RetouchPipeline.renderPass`、`RetouchStudioView` 等全部沿用原签名。
- **回退**：把上面一行换成 `return applyLegacy(to: image, skinMask: skinMask, context: context)`
  就回到旧实现（旧代码原样保留成 `applyLegacy`，方便 A/B 对比）。
- **相机配置文件**：把 `.dcp` 放到 App 可读目录，用
  `LightroomLook.loadDCPProfile(named:in:)` 读出来，再传给 `applyWithACREngine(profile:)`。
- **线性域判定**：引擎自己看 `context.workingColorSpace`。是 extended linear sRGB 就按线性算，
  否则自动切显示域，避免双重 gamma 把画面压灰。

---

## 5. 验证

```bash
# 只编译引擎 + 测试（macOS，不需要 Xcode 工程）
swiftc -O OutdoorPhotoAssistant/Core/CommercialRetouch/ACRDevelopEngine.swift \
       tests/acrdevelop/main.swift -o /tmp/acrdevelop
/tmp/acrdevelop          # 期望：PASS 40+ 项断言全部通过
```

断言覆盖面（方向 + 量级，不是像素死值）：

| # | 断言 | 参考值 |
|---|---|---|
| 1 | 中性参数逐像素原样返回 | 平均差 < 0.5/255 |
| 2 | 曝光 +1EV | sRGB 0.5 → **0.686**（线性 ×2） |
| 3 | 对比度 +100 | 0.40/0.60 → **0.315/0.685**，差 0.369 |
| 4 | blacks +15 | 0.5 → **0.489** |
| 5 | 去雾 80 | 局部对比不下降、整体亮度不暴涨 |
| 6 | Clarity 100 | 梯度能量上升、均值变化 < 3% |
| 7 | Texture 100 | 细节上升、均值变化 < 3% |
| 8 | 锐化 80 | 梯度能量上升 |
| 9 | 亮度降噪 90 | 方差下降 |
| 10 | 颗粒 100 | 方差上升 |
| 11 | 暗角 -80 | 四角 < 中心 |
| 12 | 点曲线 | 命中 (0.5, 0.62)、全程单调 |
| 13 | 颜色分级 | 暗部染色、高光不受阴影轮影响 |
| 14 | DCP 解析 | 手搓 TIFF 能读出名字与 9 元素矩阵 |
| 15 | 强度缩放 | 幅度减半、结构参数不变 |

`tools/acr_parity.py` 负责把上面这些数字先算一遍（Python 复算），
顺便验证测试里手搓的那 152 字节 DCP 是否真的能被解析器读出来——两步都过了，Swift 侧的断言才有意义。

---

## 6. 性能

- 3D LUT 33³ 只烘焙一次，按 `settings.hashValue + 算法版本号` 缓存（`NSCache`）。
- 引导滤波每个半径 6 次 box blur（CIBoxBlur 是 O(1) 的），三个引导滤波阶段最多 18 次。
- 半径全部按长边比例给：`px.pixels(ratio, min:, max:)`，4K 图与 720p 预览的观感一致。
- 降噪/Clarity/Texture 建议在预览时按 `RetouchParameters.scaled(longEdge:)` 降分辨率跑，
  导出时全分辨率跑（架构上已经在用这条路径）。

---

## 7. 已知边界

1. **CIKL 没有邻域访问**：所有局部算子都用 `CIBoxBlur / CIGaussianBlur / CIMorphologyMinimum + kernel 组合`
   实现，不做手写邻域循环（那也是 Core Image 里唯一能保证性能的写法）。
2. **DCP 只解析 IFD0**：`ColorMatrix1/2`、`ForwardMatrix1/2`、`ProfileToneCurve`、`ProfileName`、
   双光源编号。`ProfileHueSatMapData`（90×30×1）暂未接进 LUT，需要时按同一套 `ACRLookCube` 机制加一层。
3. **AI 阶段不复刻**：AI Denoise / 超分 / 选择主体是 WinML+ONNX 模型（权重内嵌 108 MB `.rdata`），
   不在本引擎范围内，仍走 App 原路径或云端。
4. **不在 Kernel 里做 loop**：`vec3` 逐通道 8 带 HSL 放在 CPU 侧 LUT 烘焙里，GPU 侧只查表。

---

## 8. 外围引擎（镜头 / 几何 / 修补 / AI 替代）

见 `ACRLensRepairEngine.swift`。要点：

1. **LCP 是 XMP**：`stCamera:` 属性，按 `ProfileName` 切段，按焦段线性插值；本机 4,424 个可直接读。
2. **畸变模型**：LCP 的 `RadialDistortParam1..3` 折算成 Brown–Conrady `k1/k2/k3`（×1e-3，方向取反），
   warp kernel 里用 2 步牛顿反解，`autoFitScale` 估算不露黑边的缩放。
3. **透视**：`homography(from:to:)` 解 8×8 线性系统拿 dst→src 逆矩阵，warp kernel 做真单应
   （不是仿射近似）。
4. **修补**：`heal` 用"偏移源图 + CIRadialGradient 羽化掩膜 + CIBlendWithMask"，
   对应 `cr_stage_heal_blend`；补光/去红眼/去紫边都是单 pass CIColorKernel。
5. **AI 只能给替身**：CNN 去马赛克、AI Denoise、生成式扩展依赖内嵌 ONNX 权重，无法离线复刻；
   这里给的是经典退化路径（强引导滤波 / Lanczos / 中心先验蒙版），接口保持同形状，后续可替换。
