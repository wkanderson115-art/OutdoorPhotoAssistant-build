部署补充：已添加Render配置 `render.yaml` 和中文步骤 `RENDER_DEPLOY.md`，使用平台自带HTTPS地址，无需购买域名。单个服务运行API和worker，共享持久磁盘，进程异常会退出并交由平台重启。包含22项后端/进程测试，均通过；尚未实际创建Render服务或验证付费模型连接。

# 当前版本：后端代理、可靠图片任务与实时预览（2026-10-24）

本次已修改App源码，并附 `server/` 可部署后端。**尚未部署服务器、未接真实Key、未通过Xcode编译或iPhone实测。** 不能将本包当作已经连通的安装版。

- 供应商Key只放服务器环境变量，App移除原有两个Key输入框和直连代码；Apple登录+个人会话，鉴权下载。
- 选中照片后才上传，建议与精修分开确认；上传前缩小和移除元数据；原片与AI成片保留为不同版本。
- 后端持久任务、同编号幂等、额度、查询及下载恢复；普通重复点击先取回原任务，明确新建才再次生成。
- 实际移植CainCamera的两段高反差保留/混合公式到Core Image，加入人脸遮罩，实时预览与成片共用处理顺序。没有把Android库或Face++接进iOS；不是只在文档里引用。美颜默认关，取景页不增加按钮面板。
- 20项后端模拟测试通过；25份App Swift源码和3份Swift测试语法/工程静态检查通过。Swift行为测试仍需在macOS运行；没有把静态检查当作编译成功。

详细部署及接口：`server/README.md`。实现和边界：`reports/BACKEND_AND_REALTIME.md`。配置HTTPS域名、Apple能力和服务端Key后才可真机联调。

以下是历史版本说明，涉及“本机填写供应商Key”“直连供应商”“滤镜仅拍后生效”的旧描述已被本版本替代。

---

# 最新更新：默认自然精修

DeepSeek看图建议已加入保守摄影后期规则；Seedream直接修图也附带自然精修约束。详情见 [reports/NATURAL_POLICY.md](reports/NATURAL_POLICY.md)。已做工程与语法检查，尚未编译或真实出图测试。

# 最新更新：Figma V2界面已同步到SwiftUI源码

图库、按需处理选择、DeepSeek建议、Seedream精修与对比、API Key卡片及下载恢复状态已修改。详见 [reports/FIGMA_SYNC.md](reports/FIGMA_SYNC.md)。

这是已同步代码的工程，不再仅是设计稿。工程/语法检查通过，但尚未完成Xcode编译、运行截图或真机验证。

# 最新版本：DeepSeek + Seedream 按需修图与自有图库

版本1.1，构建6。设置 → 云端API，分别填写DeepSeek和火山方舟Key。照片先进入App本机图库，选择照片后才可获取看图建议；查看、采用并编辑建议后，再自行决定是否调用Seedream。也可跳过DeepSeek直接修图。不会每拍一张自动调用API。

使用步骤、费用控制及验证边界见 [reports/CLOUD_GALLERY_INTEGRATION.md](reports/CLOUD_GALLERY_INTEGRATION.md)。新图库保留原片及所有成片版本，不再读取系统最近照片。

已通过工程与语法检查。没有真实Key，也没有Xcode环境；尚未验证真实API连接、iOS编译或真机运行。完整工程需在Mac/Xcode或所附GitHub Actions构建，不能直接当作已签名App安装。

# 最新修订：摄影知识AI导演与自动变焦

实际移植Smartcrop构图重要性算法及KalmanFilter平滑算法，接入Vision画面分析、候选取景、设备自动变焦、曝光与滤镜。设置中开启AI导演、自动取景和自动变焦；拍后复盘可提交效果及主体大小反馈，至少3次同类反馈后采用本地偏好。

详细说明：[reports/DIRECTOR_UPGRADE.md](reports/DIRECTOR_UPGRADE.md)。

摄影知识以可执行规则接入，偏好在本机逐步更新；本轮没有训练摄影大模型。拍摄界面保持简洁。工程与语法检查通过，未执行iOS编译、行为测试或真机验证。

# 最新修订：全范围连续变焦

支持取景双指缩放、点击当前倍率展开连续滑杆，范围按摄像头实际能力读取，已移除此前2/4/8倍固定限制。详见 [reports/FULL_ZOOM.md](reports/FULL_ZOOM.md)。设置中的人像深度默认关闭，以保留完整范围；开启深度时范围受系统限制。最新设计截图：design/Continuous_Zoom.png。静态检查通过，尚未编译及真机验证。

# 本轮更新：简洁拍摄与24节摄影课程

设计稿：https://www.figma.com/design/NbsElE3GbnJRZw7QzeTlEX

最新说明见 [reports/UI_LEARNING_REDESIGN.md](reports/UI_LEARNING_REDESIGN.md)，截图见 design/Figma_Redesign.png。拍摄页清理为必要操作，全部偏好集中设置；学习页支持课程搜索、进度和本地练习推荐。本轮没有进行模型训练或接入在线大模型。静态检查通过，未编译或真机验证。

# 本轮更新：已移植NextLevel部分源码

曝光控制、变焦设置及实际倍率监听现已接入调用。详情见 [ThirdParty/NextLevel/INTEGRATION.md](ThirdParty/NextLevel/INTEGRATION.md)。本轮检查以 NEXTLEVEL_INTEGRATION_* 报告为准；前一轮报告保留为历史记录。

# 户外摄影助手 · 相机体验修订

本轮修改说明及待测项见 [reports/CAMERA_REWORK.md](reports/CAMERA_REWORK.md)。

用Mac上的Xcode打开 OutdoorPhotoAssistant.xcodeproj，选择签名团队及真机运行。也可将工程上传至自己的GitHub仓库，手动运行 iOS Build workflow，获得未签名IPA；安装前仍需签名。

当前已通过静态工程与语法检查；未在本环境编译或真机测试。实时取景为原始预览，滤镜在拍后呈现。

# 户外拍照助手 · 整理修复版

原生 SwiftUI iPhone 相机项目，最低 iOS 17.6，构建脚本要求 Xcode 26+。
应用仅使用系统框架，无第三方运行依赖。

**当前交付状态：已修改源码并通过静态检查，未完成 Xcode 编译、签名或 iPhone 实机验证，没有生成 IPA。**
当前执行环境是 Debian Linux，没有 Apple SDK、Xcode 或可用远程 macOS 构建账号。

## 目录

- `OutdoorPhotoAssistant/`：18 个 Swift 文件、权限配置、隐私清单、图标。
- `OutdoorPhotoAssistant.xcodeproj/`：Xcode 工程与共享 scheme。
- `scripts/`：静态校验、工程生成、图标生成、Debug/Release 构建脚本。
- `tests/main.swift`：使用真实 SmartShutterEngine 源码的决策测试，供 macOS CI 执行。
- `.github/workflows/ios-unsigned-build.yml`：静态检查、决策测试、双配置编译、未签名 IPA 打包。
- `reports/`：本次修复说明与实际检查日志。
- `docs/original/`：输入包附带的历史文档和旧验证日志，不代表本次验证结果。

## 本地静态检查

```bash
python -m pip install -r scripts/requirements-check.txt
python scripts/verify.py
python scripts/check_swift.py OutdoorPhotoAssistant
```

这些检查解析 Swift 语法、工程结构、资源与配置，不会进行 Swift 类型检查或 iOS 编译。

## 在 iPhone 上安装

有 Mac 时，用 Xcode 26+ 打开 `OutdoorPhotoAssistant.xcodeproj`，选择 iPhone，
在 Signing & Capabilities 选择自己的 Apple 开发 Team，使用唯一 Bundle Identifier，点击 Run。
iPhone 需按 Xcode 提示启用开发者模式并信任开发者。签名凭据应留在自己的 Mac 上。

也可以将本目录的内容作为 GitHub 仓库根目录上传（必须包含隐藏的 `.github` 目录），
在 Actions 中运行 `iOS Build (unsigned IPA)`。成功后下载 `OutdoorPhotoAssistant-unsigned-ipa`。
这是待签名的构建产物，必须经自己的 Apple ID/开发者证书签名后才能安装；不能直接在 iPhone 上点开安装。

在已配置的 Mac 上执行 `bash scripts/build_unsigned_ipa.sh` 可构建 Debug、Release 并打包未签名 IPA。
脚本会在缺少 macOS/Xcode/iOS 26 SDK 时明确退出，不会生成伪装的安装包。

本次问题、修复与未验证项详见 [修复报告](reports/REPAIR_REPORT.md)。
