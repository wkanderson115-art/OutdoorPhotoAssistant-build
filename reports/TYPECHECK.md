# 类型检查闸门（TYPECHECK）

本文说明 `scripts/typecheck.sh`、CI 里的 `typecheck` job，以及怎么读结果和排错。
全部内容针对本仓库 `OutdoorPhotoAssistant`（iOS 17.6+，SwiftUI，未签名构建）。

---

## 1. 为什么需要它

以前的 CI 只有两类检查，都挡不住「编译前源码里的类型错误」：

| 检查 | 能抓什么 | 抓不到什么 |
| --- | --- | --- |
| `scripts/check_swift.py`（tree-sitter） | 括号/结构不平衡、语法碎片、明显的解析错误 | 未定义符号、参数标签错误、类型不匹配、API 版本问题 |
| `scripts/verify.py` | pbxproj 一致性、Sources 登记、plist、资源、workflow YAML、禁用 API 字符串 | 语义层面的一切 |
| `xcodebuild`（build job） | 全部语义错误 | ——但它是最后一道，反馈慢，而且类型错误会连带把 IPA 产物一起打掉 |

`swiftc -typecheck` 正好补上中间这层：

- **不做代码生成、不产生产物**，只跑语义分析，几秒到十几秒就能出结果；
- 抓的是真正会让 `xcodebuild` 失败的那批错误：**未定义符号 / 参数标签写错 /
  类型不匹配 / 缺少协议实现 / iOS 版本 API 不可用 / actor 隔离违规**；
- 因为它只要求「能通过类型检查」，**不要求 app target 能链上全部资源**，
  所以可以在 build 之前的独立 job 里跑，不占用 40 分钟的构建窗口。

一句话：`-typecheck` 把「类型错误」从「构建末期才炸」提前到「编译前源码」阶段。

---

## 2. 本地怎么跑

只能在 **macOS + 完整 Xcode** 上跑（不是 Command Line Tools）：

```bash
# 在仓库根目录
bash scripts/typecheck.sh
```

脚本自己会 `cd` 到仓库根，所以在任何目录调用都行。可选环境变量：

```bash
SOFT_TESTS=1 bash scripts/typecheck.sh   # 自测台失败降级为警告（默认关闭）
```

退出码：

| 退出码 | 含义 |
| --- | --- |
| `0` | 全部通过（`RESULT: PASS`） |
| `1` | 至少一项失败（`RESULT: FAIL（N 项失败）`） |
| `2` | 环境不满足：不是 macOS 或没有 `xcrun`/`xcodebuild`，打印「需要 macOS + Xcode」 |

脚本做的五件事：

1. **选最新 Xcode**：`find /Applications -maxdepth 1 -name 'Xcode*.app' | sort -V | tail -n 1`
   + `xcode-select --switch`，打印 `xcodebuild -version`、`xcode-select -p`、
   `xcrun --sdk iphoneos --show-sdk-path`、SDK 版本。
   （CI runner 上 `sudo` 免密；本地没有 sudo 权限时沿用当前选择，不因此中断。）
2. **类型检查 app 源码**（核心）：

   ```bash
   xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios17.6 \
       -swift-version 5 $(find OutdoorPhotoAssistant -name '*.swift' | sort)
   ```

   实际实现用数组收集文件列表（`while IFS= read -r ... < <(find ... | sort)`），
   路径带空格也不会被拆词，也不会因为 `find` 空结果在 `set -euo pipefail` 下炸掉。
3. **仓库自查**：
   - `python3 scripts/check_swift.py OutdoorPhotoAssistant`
   - `python3 scripts/verify.py`
   - 若 `scripts/requirements-check.txt` 存在且缺依赖，先
     `python3 -m pip install -r scripts/requirements-check.txt`（CI 里前面已装过，这里是本地兜底）。
4. **编译并运行自测台**（编译失败和运行期断言失败都算失败，不静默跳过）：

   | 测试台 | 编译命令 |
   | --- | --- |
   | shutter | `xcrun swiftc OutdoorPhotoAssistant/Core/Analysis/SmartShutterEngine.swift tests/main.swift -o build/shutter-tests` |
   | director | `xcrun swiftc OutdoorPhotoAssistant/Core/Analysis/DirectorEngine.swift tests/director/main.swift -o build/director-tests` |
   | layout | `xcrun swiftc OutdoorPhotoAssistant/Features/Capture/CaptureLayout.swift tests/layout/main.swift -o build/layout-tests` |
   | analysis | `xcrun swiftc OutdoorPhotoAssistant/Core/Analysis/FrameScoring.swift OutdoorPhotoAssistant/Core/Analysis/DirectorEngine.swift tests/analysis/main.swift -o build/analysis-tests` |
   | cloud | `xcrun swiftc -parse-as-library OutdoorPhotoAssistant/Core/Cloud/CloudAPI.swift OutdoorPhotoAssistant/Core/Cloud/CloudConfiguration.swift tests/cloud/main.swift -o build/cloud-tests` |
   | lightroom | `xcrun swiftc -D TEST_STUBS tests/lightroom/main.swift OutdoorPhotoAssistant/Core/CommercialRetouch/LightroomPresetParser.swift -o build/lightroom-tests` |

   每个测试台编译通过后立刻执行 `build/<名字>-tests`；输出与编译日志写到
   `build/typecheck-logs/<名字>.log`，失败时脚本会把日志尾部打印出来。
   `shutter / director / layout / analysis / cloud` 的命令与现有 workflow 里的测试 step
   逐字对应，`layout`、`lightroom` 是本次补齐的回归保护。
5. **汇总**：末尾打印

   ```text
   == TYPECHECK SUMMARY ==
   Xcode        : Xcode 26.x ...
   Xcode 路径   : /Applications/Xcode.app/Contents/Developer
   SDK          : /Applications/Xcode.app/.../iPhoneOS26.sdk (26.0)
   目标三元组   : arm64-apple-ios17.6
   app 源文件数 : 63            # 动态统计 OutdoorPhotoAssistant/ 下全部 .swift
   日志目录     : build/typecheck-logs
   PASS  类型检查 app 源码（63 个文件，swiftc -typecheck）
   PASS  tree-sitter 语法检查（scripts/check_swift.py）
   PASS  项目一致性检查（scripts/verify.py）
   PASS  自测台 shutter
   ...
   RESULT: PASS
   ```

---

## 3. CI 里怎么看结果

`.github/workflows/ios-unsigned-build.yml` 里新增了一个**独立 job**：

```yaml
  typecheck:
    runs-on: macos-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Select newest installed Xcode        # 与 build job 同一套选 Xcode 写法
      - uses: actions/setup-python@v5              # 3.12
      - name: Install verification dependencies     # pip install -r scripts/requirements-check.txt
      - name: Type-check app sources and run test harnesses
        run: bash scripts/typecheck.sh
```

- 它**没有** `needs:`，现有 `build` job 也**没有** `needs: typecheck`：
  两条流水线互相独立，类型检查红了不影响未签名 IPA 照常产出。
- 在 Actions 页面左侧会看到两个 job：`build`（出 IPA）和 `typecheck`（类型闸门）。
  点开 `typecheck` → 最后一步的日志，直接看 `== TYPECHECK SUMMARY ==` 与
  `RESULT: PASS/FAIL`；失败项前面有 `FAIL` 行，完整编译日志在 artifact 里看不到，
  但失败日志尾部已经打印在 step 日志中。
- 想把它改成阻塞式（类型检查不过就不出 IPA），在 build job 的第一行加
  `needs: typecheck` 即可——本任务按要求没有加，保留两条独立线。

---

## 4. 已知限制

1. **Windows 开发机跑不了。** 没有 `swiftc`，脚本会打印「需要 macOS + Xcode」并
   `exit 2`。Windows 上只能跑 `python scripts/verify.py` 与
   `python scripts/check_swift.py`（纯语法 + 项目一致性），类型错误只能等 CI。
2. **只覆盖真机架构。** `-target arm64-apple-ios17.6` 只做 arm64 设备切片，
   不含 `arm64-apple-ios17.6-simulator`。模拟器专属 API 差异（例如某些
   `#if targetEnvironment(simulator)` 分支）不在本闸门覆盖范围内；需要时再加一条
   `-target arm64-apple-ios17.6-simulator` 的 `-typecheck`。
3. **`-typecheck` 不是链接。** 它不检查资源是否打进 bundle、不在 pbxproj 里找文件，
   所以「文件没登记进 pbxproj」由 `scripts/verify.py` 负责，别指望 `-typecheck`。
   两者互补，缺一不可。
4. **不覆盖本地精修层的全部 UIKit/Vision 测试台。** `tests/retouchkit`、
   `tests/batch`、`tests/reshape`、`tests/background`、`tests/delivery` 在 workflow 里走
   `iphonesimulator` 的 `-typecheck`（不执行），`tests/fusion` 需要 Mac Catalyst 运行；
   本脚本的「跑起来」只覆盖 Foundation-only 的六个台子，其余留给现有 build job。
5. **不装任何第三方工具。** 只用 Xcode 自带（`xcrun`/`swiftc`/`xcodebuild`）与仓库已有的
   pip 依赖；不联网、不下载。
6. **`SOFT_TESTS=1` 只降级自测台。** 类型检查、两个自查脚本永远硬失败；软降级仅用于
   「本地正改测试台、想先看类型结果」的场景，CI 永远不设这个变量。

---

## 5. 排错指引：常见失败类型

### 5.1 未定义符号 / `cannot find 'Xxx' in scope`

- 通常是**新文件没登记进 `project.pbxproj`**：`scripts/verify.py` 的
  「Sources phase matches Swift files on disk」会直接报出来，先修 pbxproj（
  `scripts/gen_pbxproj.py` / `scripts/make_app.sh` 那条生成链），再重跑本脚本。
- 也可能是**文件加进了 target 但漏了 `import`**，或者声明被写进了
  `#if TEST_STUBS` 之类的条件区里。

### 5.2 `value of type 'X' has no member 'y'` / 参数标签错误

- 组内改名、签名改了但调用方没跟上，典型如 `DirectorDecision.summary`、
  `RetouchOutcome` 这类跨文件结构体。看报错里的
  `note: candidate has non-matching type/label` 就能定位改哪儿。

### 5.3 `is only available in iOS 18.0 or newer`（API 版本问题）

- 工程部署目标是 iOS 17.6，凡是用到 iOS 18+ API 的地方都必须
  `if #available(iOS 18.0, *) { ... }`（参考 `Core/Analysis/FrameAnalyzer.swift`
  里 aesthetics request 的写法）；缺 guard 时 `-typecheck` 会直接报可用性错误。
- 反过来`scripts/verify.py` 的禁用 API 列表（iOS 27 专有 API、`AVCaptureISOAuto` 等）
  是「字符串级」兜底，两者一起用。

### 5.4 actor / `@MainActor` 隔离

- 典型报错：`call to main actor-isolated instance method ... in a synchronous
  nonisolated context`。SwiftUI `View` 的 body 在主 actor 上，`Task.detached`
  或普通 `func` 里调用 SwiftUI / UIKit 主线程 API 就会报这个。
  修法：给方法标注 `@MainActor`，或把调用点放进 `Task { @MainActor in ... }`。
- 注意：`-typecheck` 的隔离检查在 `-swift-version 5` 下是**警告/错误混合**，
  报错文案可能带 `this is an error in Swift 6 language mode`，本工程按 5 模式编译，
  这类提示只要不是 `error:` 就不用管。

### 5.5 自测台编译失败

- 先看 `build/typecheck-logs/<名字>.log`。最常见的是**测试台依赖的 app 源文件被挪了位置**
  （命令里的相对路径对不上），或自测台需要 `-D TEST_STUBS` 却漏传。
- 自测台断言失败会打印 `FAIL: xxx`，同时脚本 `RESULT: FAIL`；如需临时放行用
  `SOFT_TESTS=1`（CI 不开）。

### 5.6 `需要 macOS + Xcode`（exit 2）

- 正常运行环境问题：确认 `xcode-select -p` 指向 `/Applications/Xcode*.app/Contents/Developer`
  而不是 `/Library/Developer/CommandLineTools`；CI 上确认 runner 是 `macos-latest`。

---

## 6. 相关文件

| 文件 | 作用 |
| --- | --- |
| `scripts/typecheck.sh` | 本闸门本体（五步，一条命令跑完） |
| `.github/workflows/ios-unsigned-build.yml` | 新增独立 `typecheck` job；现有 `build` job 未改 |
| `scripts/check_swift.py` | tree-sitter 语法检查（被本脚本调用） |
| `scripts/verify.py` | 项目一致性检查（被本脚本调用，含 workflow YAML 解析） |
| `scripts/requirements-check.txt` | Python 检查依赖（tree-sitter / pbxproj / PyYAML） |
| `build/typecheck-logs/` | 本脚本的运行日志（不入库） |
