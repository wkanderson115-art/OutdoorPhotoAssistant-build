# 修复清单：从「无法编译 / 必崩」到「可构建、可侧载」

对照上一轮审查报告逐条落实。级别：**P0 = 编译失败或必崩**，**P1 = 功能错误/明显体验缺陷**，**P2 = 工程质量**。

## P0-A 编译失败（8 处，全部修复）

| # | 原位置 | 原问题 | 修复方式 |
|---|---|---|---|
| E1 | `CameraService:106` | `device.lowLightBoostSupported` 属性名不存在 | 改为 `device.isLowLightBoostSupported`（`AdaptiveCameraEngine` 中统一处理） |
| E2 | `CameraService:146` | 在非 `@available` 方法里调用 iOS 18+ 方法 | 删除 Camera Control 相关代码（含 E3） |
| E3 | `CameraService:175-176` | `AVCaptureSystemZoomSlider()` / `AVCaptureSystemExposureBiasSlider()` 缺 `device:` 参数 | 整段移除，后续可作为独立特性按 iOS 18 守卫加回 |
| E4 | `CameraService:319` | `format.recommendedLensApertureStops`（iOS 27 API）无守卫 | 移除可变光圈特性 |
| E5 | `CameraService:330` | `format.supportsExposureModeCustom(lensAperture:…)`（iOS 27）无守卫 | 同上 |
| E6 | `CameraService:331` | `setExposureModeCustom(lensAperture:…)` + `AVCaptureExposureDurationAuto`/`AVCaptureISOAuto`（iOS 27，且 Swift 已改名） | 改为只做 `setExposureTargetBias` 曝光补偿 |
| E7 | `FrameAnalyzer:123` | `VNCalculateImageAestheticsScoresRequest`（iOS 18）无守卫 | 用 `if #available(iOS 18.0, *)` 包裹，低版本自动跳过审美分 |
| E8 | `DepthPortraitProcessor:11,22` | `oriented(forExifOrientation:)` 需要 `Int32`，传的是枚举 | 统一改用 `oriented(_:)` + `PhotoPostProcessor.exifOrientation(_:)` |
| E9 | `project.pbxproj` | target 只有 Release 配置，scheme 用 Debug → Xcode 无法运行 | 重新生成工程文件，Debug + Release 双配置（脚本 `scripts/gen_pbxproj.py`，可重复生成） |
| E10 | `project.pbxproj` | `SWIFT_VERSION = 5.9` 不是合法语言模式 | 改为 `5.0` |

## P0-B 运行必崩（1 处，已修）

| 问题 | 根因 | 修复 |
|---|---|---|
| 按快门抛异常崩溃 | `AdaptiveCameraEngine` 打开了**照片级** `isDepthDataDeliveryEnabled` / `isPortraitEffectsMatteDeliveryEnabled`，但 `CameraService` 从未打开**输出级**同名开关。Apple 文档明确：输出级不开启时请求人像光会抛异常 | `CameraService.configureAdvancedCaptureSupport()` 在 `startRunning` 之前打开输出级 depth → matte；`prepare()` 只在输出级已开启时往照片请求里加，并让 RAW/高清路径不请求 depth |

## P0-C 死逻辑（已改成真的能用）

| 功能 | 原问题 | 修复 |
|---|---|---|
| 自动拍摄 | 评分上限 86 < 阈值 88，永远不触发 | 评分改为 0–100 分项（三分 40 + 水平 25 + 曝光 20 + 留白 15），阈值 76（有主体）/66（无主体）+ 连续 3 帧确认 + 倒计时二次确认 |
| 深度/3D 人像 | 开关没开 + 基底未旋转导致遮罩错位 | 开关修正 + 底图与遮罩统一到正立坐标系后再精确贴齐 |
| ProRAW | 请求 DNG 却用 `UIImage(data:)` 解码 → "无法解码" | 改为「高清」模式：请求设备支持的最大照片尺寸 + quality 优先，不再碰 RAW |
| 可变光圈 | iOS 27 API，且 iPhone 基本没有可变光圈 | 移除，改为通用曝光补偿 |
| 时段调色 | `period` 恒传空串，黄金/蓝调分支永不生效 | `FrameAnalyzer.setPeriod()` 由 `CaptureView` 监听 `location.periodText` 注入；滤镜、调色、建议都会用到 |
| 构图风格（自然/电影/主体） | 只有两个分支且与实际画面无关 | 三个风格都通过 `ColorGrade.applyingStyle` 真正作用于成片 |
| 场景识别 | 按候选顺序匹配，忽略置信度；人物恒 0.9 假置信度 | 按置信度择优 + 0.12 门槛 + 场景连续 3 帧滞回；人物加人脸面积门槛 |
| 点按对焦 | 用 `UIScreen.main` 手算坐标，竖屏下有偏移 | 改为 `AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)` |
| 0.5×/自动选镜头 | 场景抖动时反复重配 session | 1.2 s 防抖 + 只在需要时切输入；拍照飞行中不重配（排队 pendingZoom） |
| 主线程渲染 | 4–5 张全分辨率 Core Image 在主线程跑，峰值 200–400 MB | 全部后处理移到全局队列；共享一个 `CIContext`；`CIColorCube` 带缓存；一次拍摄只保留「原片字节 + 成片」 |
| 连拍存一堆 | burst 每一帧都保存 4–5 张 | 移除 burst，单帧最佳 |
| 原片丢元数据 | 用 `UIImage` 重编码，EXIF/GPS/深度全丢 | 原片用 `PHAssetCreationRequest.addResource(.photo, data:)` 按原始字节写入；成片另存 JPEG |
| 美颜遮罩 | 512×512 方形遮罩贴到 3:4 画面 → 磨皮/瘦脸打错位置 | 遮罩画布按图像宽高比创建 + 非等比精确贴齐 |
| 色相分桶 | 青色区间 165–255 吃掉天空蓝 | 改为 165–200 青 / 200–255 蓝 |
| 阴影提亮 | `shadowAmount = 1 + shadows/50` 恒被 clamp 到 1（等于没提） | 改为 `shadows/20` 映射到 0…1 |
| 错误静默 | `errorMessage`/权限状态从不显示 | 拍摄页顶部红条 + 相机权限引导 + 保存失败 toast |
| Review 编辑基准跳变 | 一拖滑杆从"风格版"跳到"原片+美颜" | 统一管线：原片 → 美颜 → 滤镜 → 调色，滑杆刷新走同一条 |
| Review 保存 | 固定 0.2 s 后 dismiss，不看结果 | 用保存回调，成功才 dismiss，失败显示原因 |

## P2 工程质量

- 新增 `Assets.xcassets`（1024 AppIcon + AccentColor），侧载后不再是白图标。
- `Info.plist` 补 `UILaunchScreen`、竖屏锁定、`ITSAppUsesNonExemptEncryption=false`、版本号变量。
- 新增 `PrivacyInfo.xcprivacy`（UserDefaults / CA92.1），上架 App Store 时不会被直接拒。
- 新增 `.github/workflows/ios-unsigned-build.yml`：**Debug + Release 双构建**，失败上传日志，成功上传未签名 IPA。
- 新增 `scripts/`：工程文件生成、图标生成、Swift 语法/工程结构静态校验、本地打未签名 IPA。
- 删除死代码 `Advisor.swift`；`AdaptiveCameraEngine` 的档位字段全部被实际消费。
- 视图按关注点拆分（`DirectorCard` / `QualityCard` / `PermissionHint`），分析结果 5 Hz 节流，降低整页重绘。
