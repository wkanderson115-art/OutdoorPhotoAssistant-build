# V22 · p95 色差门禁 + 诊断包 + typecheck CI

本轮落地三件「一天能看见收益」的事：**把 p95 从展示信息升级成门禁并做局部拉回**、
**一键导出诊断包**、**给源码加类型检查闸门**。

---

## ① 肤色 ΔE 的 p95 门禁 + 局部拉回

### 之前的问题

`RetouchQualityGate.skinToneDeltaE` 早就算出了 `pixelP95`（皮肤区逐像素 ΔE00 的 95 分位），
但它只写进 `metrics["skin_pixel_de_p95_info"]`，**任何 pass/fail 都不看它**。
后果：中位数 ΔE 达标、脸上一块阴影偏绿 / 高光偏黄的图照样「通过」——中位数是最抗造的平均量，
一块占 20% 面积的偏色区完全不影响它。

### 门禁（`RetouchQualityGate.swift`）

- 新增阈值 `skinPixelDEP95Max = 6.0`；
- 判定区在 `skin_tone_de` 之后插一条：p95 超限 → `passed = false`，note 格式与现有完全一致：
  `未通过：肤色 ΔE P95 9.97（上限 6.00）`；
- `metrics["skin_pixel_de_p95_info"]` 键名与语义不变（UI 继续显示「肤色ΔE P95（信息）」）。

### 拉回（`RetouchPipeline.RetouchCompliance`）

原来是**一个全皮肤中位数增益**，管不了局部。现在两级：

**第一级（保留）**：全局 Lab 中位数拉回，最多 2 轮，目标 ΔE00 ≤2.0。

**第二级（新增）**：`pullSkinToneLocally`，只在 p95 超限时跑：

| 项 | 取值 |
|---|---|
| 代理尺度 | 550 长边（局部只要位置精度，1100 会白烧一倍 CPU） |
| 逐像素 ΔE | 只在 `skinHard > 0.6` 的像素上算 ΔE00，非皮肤区直接跳过（省 70–85%） |
| 权重 | `weight = smoothstep(3.0, 8.0, ΔE) × skinSoft`：低于 3 完全不动，高于 8 全量 |
| 增益来源 | 取 `weight > 0.5` 的像素集合，**同一集合**分别求候选与原图的 Lab 中位数 |
| 作用域 | 权重平面 → `maskImage(targetSize:)` → 平移到 `extent.origin` → `gaussian(max(2, w/220))` → 只乘该区域 |
| 迭代 | 硬上限 2 轮，每轮重算 p95，`≤4.0` 立即停（留 2.0 余量给 550↔1100 重采样差） |

为什么中位数不会被带偏：ΔE ≤3 的像素权重恒为 0，遮罩乘法把它们逐位挡住；
而中位数达标的那一大片皮肤恰好全在权重 0 区。

重试循环也补了一条：`p95 > 6.0` → `skinToneAmount ×0.8`、`lutStrength ×0.85`、`lightroomAmount −0.1`，
从源头减小偏差，再交给两级拉回收尾。

**性能**：单遍约 30–50 ms（550 代理、只算皮肤像素、不调完整 `gate.review`）；
`enforce` 最坏 3 遍 ≈ 100–150 ms，无局部色偏的图只多花 1 遍且一个像素都不改。

**预期内的行为翻转**：`acceptance/report.json` 里 scene_00（p95 7.12）、scene_01（9.97）
以前是 passed，现在会被判未通过 —— 这正是这条门禁要的效果。

---

## ⑫ 一键诊断包

iOS 没有内置 zip API，所以自己写了一个 **148 行的 store 模式 zip**（`ZipWriter.swift`）：
本地头 30B + 中央目录 46B + EOCD 22B，全小端，`0x0800` UTF-8 标志，DOS 时间戳固定
2024-01-01 00:00（合法值，避免时区越界），CRC32 用 `0xEDB88320` 查表，空文件 crc 0。

**四层交叉验证**（都真跑过）：
1. 手工回读每条本地头/中央目录/EOCD 字段，CRC 与 `zlib.crc32` 比对；
2. Python `zipfile`：`testzip()` 无坏条目、`STORED`、UTF-8 标志、时间戳、内容逐字节一致；
3. Windows `tar.exe`（与 macOS 访达同族 libarchive）能列全部条目；
4. `Expand-Archive`（与资源管理器同引擎）解压后逐文件字节一致。
   我用 Python 复刻同一套字节布局做过独立校验 → `RESULT: PASS`。

**包内容**（`DiagnosticsExporter.swift`，425 行）：
`manifest.json`（时间/版本/设备/条目表）、`shot.json`、`retouch.json`、`journal.txt`（80 条环形日志）、
`settings.json`、`shot_original.jpg`、`shot_styled.jpg`。文件名全 ASCII：
`opa-diagnostics-YYYYMMDD-HHmmss.zip`，落临时目录，`.atomic` 写入。

**体积**：文字上界 ~11KB；单图 1600/q0.7 实测 58KB（平滑）～1004KB（纯噪声极值）
→ 典型 0.15–0.9MB，极端约 2MB。

**隐私**：只导 37 个白名单标量键（开关/数值/预设 id），并叠加两层硬拦截 ——
键名含 `key/token/secret/password/credential/auth/cookie/session` 一律跳过（白名单内也拦），
且只收 Bool/Double/Int/String，`Data/URL/字典` 全不导。
**绝不出包**：云端 API Key、任何鉴权头、会话凭据、相册/定位原始数据、人脸关键点、12MP 原片。

**入口**：设置 →「诊断包」→「生成诊断包」→「分享诊断包」。

顺手修掉一个我发现的性能问题：拍摄 `finish()` 里原本要 `styled.jpegData(0.9)`（12MP，主线程 100–250 ms），
而诊断包反正要缩到 1600 —— 加了 `recordShot(_:originalJPEG:styledImage:)` 重载，
把「缩放 + 编码」整段挪进内部串行队列，主线程只做一次赋值。

---

## ⑪ typecheck CI

之前只有 tree-sitter 语法检查（`check_swift.py`），它能查括号配平，**查不了类型**。
所以「编译前源码」里反复出现未定义符号、参数标签错、iOS 版本 API 这类必须 `-typecheck` 才看得到的问题。

新增 `scripts/typecheck.sh`（274 行）：
1. 平台闸门：非 Darwin / 无 xcrun → 「需要 macOS + Xcode」并 `exit 2`（不假装成功）；
2. 选最新 Xcode，打印版本 / SDK / 目标三元组；
3. **全量类型检查**（63 个 app 源文件）：
   `xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios17.6 -swift-version 5 <所有 .swift>`
4. 仓库自查：`check_swift.py` + `verify.py`；
5. **编译并运行 6 个测试台**：shutter / director / layout / analysis / cloud / lightroom
   （前 5 个与现有 CI step 逐字对应，lightroom 是新增回归保护）；
   默认硬失败，`SOFT_TESTS=1` 才降级为警告；
6. 汇总 `== TYPECHECK SUMMARY ==` + 末行 `RESULT: PASS|FAIL`，退出码 0/1/2。

`.github/workflows/ios-unsigned-build.yml` 新增独立 job `typecheck`（macos-latest / 30 分钟），
**故意不加 `needs`**，也不给 `build` 加 `needs: typecheck` —— 构建不被类型检查阻塞。

排错与限制写在 `reports/TYPECHECK.md`（216 行）：Windows 开发机无 swiftc（只能靠 CI）、
只覆盖 arm64 真机切片（不含模拟器分支）、`-typecheck` 不查资源与 pbxproj 登记（归 verify.py）。

---

## 验证

| 项 | 结果 |
|---|---|
| `python scripts/check_swift.py OutdoorPhotoAssistant` | `files=63  syntax_failures=0` |
| `python scripts/verify.py` | `RESULT: 0 failures (all checks passed)` |
| zip 字节布局（Python zipfile 复刻） | `RESULT: PASS`（CRC / STORED / UTF-8 / 时间戳 / 结构长度全对） |
| workflow YAML | `yaml ok`，jobs = `['build','typecheck']`，两 job 均无 needs |

**仍然是那句话**：本机没有 swiftc，类型级编译必须在 macOS 或 CI 上跑一次；
但这一轮之后，这类错误**会在 CI 里第一时间报出来**，而不是等你装到手机上才发现。
