# 代码审计 + Bug 修复 + 功能升级报告

**日期**：2026-10-26  
**版本**：build 28 修订

---

## 一、Bug 修复

### P0 编译错误（4个，全部修复）

| 编号 | 文件 | 问题 | 修复方式 |
|------|------|------|----------|
| P0-1 | PortraitBeautyEngine.swift:190 | `continue` 在 if 块内非循环，编译错误 | 改为 `if box.width > 2, box.height > 4 { ... }` 包裹 |
| P0-2 | PortraitBeautyEngine.swift:202 | `guard ... else { }` 空体，Swift 不允许 | 改为 `if let lipMask = ...` |
| P0-3 | PhotoLibraryService.swift:51 | `data` 未定义，应为 `encoded.data` | 修正引用 |
| P0-4 | project.pbxproj:83 | PBXGroup ID 重复定义（path="" 覆盖 path="OutdoorPhotoAssistant"） | 删除重复行 + 修复 gen_pbxproj.py 空父组跳过 |

**CI 补充**：`.github/workflows/ios-unsigned-build.yml` typecheck 文件清单补入 `FrameScoring.swift`。

### P1 逻辑缺陷（7个，全部修复）

| 编号 | 文件 | 问题 | 修复方式 |
|------|------|------|----------|
| P1-1 | ColorGrade.swift:210 | `hasSelective` 漏 `*Lum` 参数，纯明度调色静默失效 | 补 `lums` 数组检查 |
| P1-2 | FrameScoring.swift:24 | 人物不开三分加权；无主体叠加水平+亮度超分 | `ruleOfThirds: true`；无主体 `return 27` |
| P1-3 | PortraitBeautyEngine.swift:660 | `generation` 只在 enabled 变化时递增，参数变化不递增 | `if changed { generation += 1 }` |
| P1-4 | DirectorVision.swift:128 | 分割失败保留旧 extent 的 mask，画面比例变化后虚化错位 | 失败清 mask + 校验 extent 一致 |
| P1-5 | SmartShutterEngine.swift:30 | `!isStable && stability>=58` 仍可 `shootNow` | `!isStable` 直接 `.wait` |
| P1-6 | CaptureView.swift:522 | 深度遮罩虚化强度硬编码 0.18，滑杆无效 | 使用 `directorBlurStrength` |
| P1-7 | CaptureView.swift:414 | 41 个滤镜缩略图每次 body 求值同步主线程 createCGImage | 异步缓存 + 分组懒加载 |

### P2 文案与一致性问题

- PhotoFilter.swift 注释 "42 套" → "41 套"
- SettingsView 滤镜种类文案同步更新
- ReviewView 景深指标改为 `depthMask`（不再依赖未使用的 `depthPortrait`）

---

## 二、功能升级

### 升级 1：眼影/眼线/双眼皮（美妆补齐）

**实现文件**：PortraitBeautyEngine.swift + ReviewView.swift

- `PortraitBeautySettings` 新增 `eyeshadow`、`eyeliner`、`doubleEyelid` 三参数（默认 0）
- 自然模式自动封顶 0.30，进阶模式 1.0（通过 `clamp` 列表生效）
- 三段处理逻辑插入在唇形之后、美白之前：
  - **眼影**：上眼睑折线向上偏移 0.45 眼高形成带状多边形，CIColorControls 加深+提饱和+柔羽化
  - **双眼皮**：上眼睑上方两条窄带（0.18 和 0.06 眼高），上暗下亮微对比
  - **眼线**：上眼睑折线描边，新增 `drawStrokedPath` 方法（round cap/join），降亮度提对比，不模糊
- 新增遮罩辅助方法：`eyeshadowMask`、`eyelidBands`、`eyelinerMask`、`drawStrokedPath`
- ReviewView "五官" Section 后新增 "眼妆" Section（三个 slider）
- 仅在检测到人脸时生效，无人脸返回 nil

### 升级 2：曲线/LUT 调色

**实现文件**：ColorGrade.swift + ReviewView.swift

- `ColorGrade` 新增 `curveShadow`、`curveMid`、`curveHighlight` 三参数（-1...1，默认 0）
- 电影风格自动带轻微 S 曲线（curveShadow -0.06, curveHighlight -0.05）
- `ColorGradeEngine.apply` 管线在 cube 之后、clarity 之前插入 `applyToneCurve`
- 使用 `CIFilter(name: "CIToneCurve")` + 5 个 `CIVector` 控制点
- 强制单调递增 clamp（s ≤ m ≤ h）
- ReviewView 新增 "曲线调色" Section（三个 slider -0.35...0.35 + 重置按钮）
- `render()` 在 grade 重置之后叠加用户曲线参数

### 升级 3：滤镜缩略图分组 Tab

**实现文件**：PhotoFilter.swift + CaptureView.swift

- `PhotoFilter.swift` 新增 `FilterGroup` 枚举（基础/人像/风景/时段/胶片/黑白/艺术）
- `PhotoFilter.group` 计算属性 + `filters(in:)` 方法
- CaptureView 效果面板改为：
  - 顶部 7 个分组 chip（横向滚动 Capsule）
  - 下方 `LazyHStack` 只显示当前组滤镜（5-10 个）
  - `@State filterThumbnails` 字典缓存
  - `.task(id: filterGroup)` 异步预取本组缩略图（底图缩到 120px 长边，后台 createCGImage）
  - 面板打开时清空缓存用当前画面重新生成

---

## 三、测试补充

| 文件 | 新增断言 |
|------|----------|
| tests/main.swift | `!isStable && stability=90` → `.wait` |
| tests/analysis/main.swift | `emptyScore == 27`（无主体精确 27 分） |

---

## 四、修改文件清单

| 文件 | 改动类型 |
|------|----------|
| PortraitBeautyEngine.swift | P0-1, P0-2, P1-3, 升级1 |
| PhotoLibraryService.swift | P0-3 |
| project.pbxproj | P0-4 |
| scripts/gen_pbxproj.py | P0-4 根因 |
| .github/workflows/ios-unsigned-build.yml | CI 补 FrameScoring |
| ColorGrade.swift | P1-1, 升级2 |
| FrameScoring.swift | P1-2 |
| DirectorVision.swift | P1-4 |
| SmartShutterEngine.swift | P1-5 |
| CaptureView.swift | P1-6, P1-7, 升级3 |
| PhotoFilter.swift | 升级3 |
| ReviewView.swift | 升级1, 升级2, P2 |
| SettingsView.swift | P2 文案 |
| tests/main.swift | 测试补充 |
| tests/analysis/main.swift | 测试补充 |

---

## 五、验证状态

当前环境无 swiftc/Xcode，以下为静态验证：
- 所有 P0 编译错误的语法模式已消除（continue→if、guard→if let、未定义标识符→正确引用、pbxproj 无重复 ID）
- P1 逻辑修复对照测试断言设计意图一致
- 升级 1/2/3 的代码结构与现有模式（口红范式、ColorGrade 管线、PhotoFilter 枚举）一致
- **需在 Xcode 中完成一次 Debug/Release 构建确认**
- **需在真机上验证眼妆效果（避免虹膜染色）、曲线调色观感、滤镜分组滚动流畅度**
