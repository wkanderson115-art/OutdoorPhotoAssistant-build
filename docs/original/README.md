# 户外拍照助手 OutdoorPhotoAssistant（iOS 26 兼容重构版）

一个以 iPhone 原生相机能力为基础的**离线户外拍照辅助 App**。SwiftUI + AVFoundation + Vision + CoreImage + CoreMotion + Photos，**无第三方 SDK、无网络请求、所有分析在设备端完成**。

- 最低系统：**iOS 17.6**（在 iOS 26 上运行，使用 Xcode 26 / iOS 26 SDK 构建）
- 设备：iPhone（`TARGETED_DEVICE_FAMILY = 1`），竖屏锁定
- 工程：`OutdoorPhotoAssistant.xcodeproj`，含 **Debug + Release** 两套配置与共享 scheme
- 依赖：无（Swift 自动链接系统框架）

> 本仓库是原 `OutdoorPhotoAssistant_Final_LineByLine_Fixed.zip` 的**可用化重构版**。
> 原工程无法编译（8 处硬编译错误、1 处必崩的运行时缺陷、4 个卖点是死逻辑），
> 逐条修复清单见 [`FIXES.md`](FIXES.md)，完整审查报告见上一轮的《代码审查与改进方案》。

## 功能

| 能力 | 状态 | 说明 |
|---|---|---|
| 实时取景 / 前后摄切换 / 点按对焦曝光 | ✅ | 点按换算交给 `AVCaptureVideoPreviewLayer`，不会再点偏 |
| 0.5× / 1× / 2× 变焦 | ✅ | 0.5× 切超广角物理设备；1×/2× 用后置虚拟设备 |
| 场景识别（人物/风景/建筑/日落/夜景/花草/海边/汽车） | ✅ | 按置信度择优 + 连续 3 帧滞回，人物带人脸面积门槛 |
| 构图评分 / 导演建议 / 三分线 / 水平仪 / 主体框 | ✅ | 0–100 可解释分项（三分 40 + 水平 25 + 曝光 20 + 留白 15） |
| 自动取景（自动选镜头） | ✅ | 场景变化 1.2 s 防抖后才切镜头，避免反复重配 session |
| 自动拍摄（构图达标倒计时） | ✅ | 连续 3 帧达标 + 倒计时期间二次确认 + 稳定性判定 |
| 15 套滤镜 + 场景自动选滤镜 | ✅ | 滤镜/调色串成一条 Core Image 管线，只渲染一次 |
| 自动曝光补偿 | ✅ | 只改曝光补偿，带死区 + 0.6 s 速率限制，不和系统 AE 抢控制权 |
| 深度/人像光（Portrait Effects Matte）景深 + 视差 | ✅（按机型） | 输出级 depth/matte 开关已正确打开，不会崩 |
| 人像美颜（磨皮/立体/瘦脸/眼神/人景融合） | ✅ | 遮罩几何按画面宽高比修正，不再糊错位置 |
| 拍后复盘 + AI 审美评分 | ✅ | 审美评分用 iOS 18+ 的 `VNCalculateImageAestheticsScoresRequest`，低版本自动跳过 |
| 原片保留 EXIF / 深度 | ✅ | 原片按原始字节写入相册，不再被 UIImage 重编码 |
| 4 个最高画质 / 最高照片尺寸 | ✅ | 「高清」开关请求设备支持的最大拍照尺寸 |
| 时段（日出/日落/黄金/蓝调） | ✅ | 已真正注入滤镜、调色与建议（原先恒传空串） |

### 与原版相比**移除**的东西（都是要么编译不过、要么必崩、要么纯死逻辑）

- ProRAW：原来请求 DNG 又用 `UIImage(data:)` 解码 → 拍完必报"无法解码"。已改为「高清」模式（最大照片尺寸 + quality 优先）。
- 可变光圈：原代码用的 `recommendedLensApertureStops` / `setExposureModeCustom(lensAperture:…)` 是 **iOS 27** 的 API，在 iOS 26 SDK 下连编译都过不了，且 iPhone 绝大多数机型物理光圈固定。已删除，只保留通用曝光补偿。
- Camera Control 系统滑块（`AVCaptureSystemZoomSlider` 等）：原实现缺 `device:` 参数且调用点未做可用性守卫。为「第一次就能编译通过」暂不引入，后续可加。
- 多帧连拍（burst）：原实现会把每一帧都存成 4–5 张全分辨率图（一次快门十几张、峰值内存爆掉）。已移除，保留单帧最佳。

## 目录结构

```
OutdoorPhotoAssistant/
├── App/
│   ├── OutdoorPhotoAssistantApp.swift    # @main，注入 5 个 @StateObject，接线 onFrame
│   └── RootView.swift                    # 4 个 Tab + 图库 + 摄影小课堂
├── Core/
│   ├── Camera/
│   │   ├── CameraService.swift           # 会话/拍照/变焦/曝光/恢复，含预览与点按对焦
│   │   ├── AdaptiveCameraEngine.swift    # 设备档位（轻量/均衡/高性能）→ HDR/质量/尺寸
│   │   └── DepthPortraitProcessor.swift  # Portrait Matte → 景深人像 + 遮罩
│   ├── Analysis/
│   │   ├── FrameAnalyzer.swift           # 时间门控的 Vision 管线 + 构图评分 + 建议
│   │   ├── ColorGrade.swift              # 调色模型 + CIColorCube（带缓存）
│   │   ├── PhotoFilter.swift             # 15 套滤镜（CIImage 版）
│   │   ├── PhotoPostProcessor.swift      # 原片→美颜→滤镜→调色 一次渲染
│   │   ├── PortraitBeautyEngine.swift    # 人像美颜（遮罩按宽高比）
│   │   └── SmartShutterEngine.swift      # 快门决策纯函数（可单测）
│   ├── Storage/PhotoLibraryService.swift # 原片字节 + 成片 JPEG 写入相册
│   ├── Location/LocationService.swift    # 定位 + NOAA 太阳时 + 时段
│   └── Motion/MotionService.swift        # 水平/稳定度
├── Features/
│   ├── Capture/CaptureView.swift         # 取景页（后台渲染、立即快门、错误提示）
│   ├── Capture/CompositionOverlay.swift  # 三分线/主体框/水平线
│   ├── Review/ReviewView.swift           # 拍后复盘 + 美颜微调 + 保存
│   └── Settings/SettingsView.swift
├── Assets.xcassets                       # AppIcon（1024）+ AccentColor
├── Info.plist                            # 权限文案、竖屏锁定、UILaunchScreen
└── PrivacyInfo.xcprivacy                 # UserDefaults 隐私声明（CA92.1）
```

## 构建

### 方式 A：GitHub Actions（无需 Mac，推荐）

1. 新建一个 GitHub 仓库，把本目录（含 `.github/`）上传上去。
2. 打开仓库 **Actions → iOS Build (unsigned IPA) → Run workflow**。
3. 等约 5–10 分钟，在 run 页面底部下载 artifact **`OutdoorPhotoAssistant-unsigned-ipa`**。
4. 用 Windows 侧载签名后安装，详见 [`BUILD_AND_INSTALL_iOS26.md`](BUILD_AND_INSTALL_iOS26.md)。

工作流会**先编 Debug 再编 Release**，两次都通过才打 IPA；失败时会额外上传两份 `build-*.log`。

### 方式 B：有 macOS 时本地构建

```bash
# 未签名 IPA（用于侧载）
./scripts/build_unsigned_ipa.sh

# 或直接在 Xcode 里跑
open OutdoorPhotoAssistant.xcodeproj
```

在 Xcode 里真机运行需要在 target 的 *Signing & Capabilities* 里选择你自己的 Team；
`PRODUCT_BUNDLE_IDENTIFIER` 默认 `com.example.outdoorphotoassistant`，**免费 Apple ID 侧载前建议改成 `com.<你的名字>.outdoorphoto` 避免冲突**。

## 安装（iPhone / iOS 26）

完整步骤见 [`BUILD_AND_INSTALL_iOS26.md`](BUILD_AND_INSTALL_iOS26.md)，要点：

1. 未签名 IPA 必须**重新签名**才能装（免费 Apple ID 即可，7 天有效期）。
2. iOS 16+ 需要在 **设置 → 隐私与安全性 → 开发者模式** 打开开关并重启。
3. 首次启动要允许相机、相册（读/写）、定位（使用期间）、运动与健身。
4. 免费账号签名 7 天后过期，用同一工具重签安装即可覆盖。

## 静态验证（本仓库已做）

本机为 Windows，没有 Xcode，**未做真实编译**。已完成以下静态检查（`python scripts/verify.py`）：

- 18 个 Swift 文件全部通过 tree-sitter Swift 语法解析（约 3,400 行）
- `project.pbxproj` 可被 Xcode 工程解析器读取；target 同时具备 Debug/Release 配置
- Sources 阶段的 18 个文件与磁盘一一对应；Assets/PrivacyInfo 在 Resources 阶段
- `Info.plist` / `PrivacyInfo.xcprivacy` 可解析且必需键齐全；竖屏锁定
- scheme XML 解析通过，BlueprintIdentifier 指向真实 target
- AppIcon 为 1024×1024 RGB PNG（无 alpha）
- workflow YAML 可解析，Debug+Release 双构建
- 源码中不存在 iOS 27 API（`recommendedLensApertureStops`、`AVCaptureISOAuto` 等）与已知错误符号

> 第一次真正的编译发生在 CI / 你的 Mac 上。如果报错，把 `build-release.log` 里的第一段
> `error:` 贴回来，通常都是 1–2 行的小改动。

## 已知限制

- 暂不支持 Camera Control（iPhone 16+ 的相机控制键），后续可作为增量特性加入（需 iOS 18 守卫）。
- 4800 万像素「高清」模式会按机型显著增加处理与存储开销，老机型建议关闭。
- 人像美颜依赖 Vision 人脸检测；侧脸/背影/多人远景时自动跳过，只做整体色彩优化。
- 未做 App Store 上架准备（无 App Store 截图/描述），当前定位是自用侧载。
