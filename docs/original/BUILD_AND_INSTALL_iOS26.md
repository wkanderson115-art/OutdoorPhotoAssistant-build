# 从 Windows 把「户外拍照助手」装到 iPhone（兼容 iOS 26）

> 前置事实：**iOS App 必须在 macOS 上编译**（Xcode / GitHub Actions 的 macOS runner 都算）。
> Windows 只能做两件事：① 触发云端编译；② 给编译出来的未签名 IPA 做侧载签名。
> 下面是完整的、不需要买 Mac 的路线。

---

## 第 0 步：准备账号与工具

| 需要 | 说明 |
|---|---|
| GitHub 账号 | 免费即可，用来跑 macOS 云端编译 |
| Apple ID | 免费即可（用 Sideloadly/AltStore 签名，7 天有效期） |
| Windows 侧载工具 | 推荐 [Sideloadly](https://sideloadly.io/)，或 AltStore + AltServer |
| 驱动 | 安装 **Apple Devices**（Microsoft Store）或 iTunes，确保 iPhone 能被 Windows 识别 |
| iPhone | iOS 26，USB 数据线 |

> 如果你有 $99/年的 Apple Developer 账号，签名有效期是 1 年，不用每 7 天重签。

---

## 第 1 步：在 GitHub 上跑云端编译（约 5–10 分钟）

### 1.1 建仓库

1. 打开 <https://github.com/new>，仓库名随意（如 `OutdoorPhotoAssistant`），**Private 或 Public 都行**。
2. 创建后点 **uploading an existing file**。

### 1.2 上传工程

把本目录**里面的所有内容**（不是外层文件夹）拖进上传框，注意必须包含：

```
OutdoorPhotoAssistant.xcodeproj/
OutdoorPhotoAssistant/
.github/workflows/ios-unsigned-build.yml
README.md
scripts/
```

- 如果浏览器拖拽时漏掉了 `.github`（隐藏目录很常见），用 **Add file → Create new file**，
  文件名输入 `.github/workflows/ios-unsigned-build.yml`，把仓库里这个文件的内容粘贴进去即可。
- 上传完点 **Commit changes**。

### 1.3 触发编译

1. 进入仓库 **Actions** 标签页，左侧选 **iOS Build (unsigned IPA)**。
2. 点右上 **Run workflow → Run workflow**。
3. 等待 job 变绿（约 5–10 分钟）。两个 build 步骤都会跑：**Build Debug** 和 **Build Release**。
4. 点进这次 run，页面底部 **Artifacts** 下载：
   - `OutdoorPhotoAssistant-unsigned-ipa` ← 你要的 IPA（已打成 zip，下载后解压得到 `.ipa`）
   - 如果失败：`build-logs`（里面是 `build-debug.log` / `build-release.log`）

> 编译失败怎么办：把 `build-*.log` 里第一条 `error:` 前后的 30 行贴回来。
> 代码已做过静态校验，但仍可能有 1–2 处只有 Xcode 才能发现的类型/API 差异，都是小改。

---

## 第 2 步：Windows 侧载签名并安装

### 2.1 安装 Sideloadly 与驱动

1. 安装 **Apple Devices**（Microsoft Store，比 iTunes 更轻）或 iTunes。
2. 安装 **Sideloadly**（官网下载，安装时允许驱动组件）。
3. 数据线连接 iPhone，iPhone 上点「信任此电脑」。

### 2.2 修改 Bundle ID（重要，避免冲突）

P1：免费 Apple ID 只能注册有限个 App ID，`com.example.outdoorphotoassistant` 可能已被占用或冲突。
**有两种改法，任选其一：**

**改法 A（推荐，在 GitHub 上改）**
1. 打开仓库里 `scripts/gen_pbxproj.py`，把 `BUNDLE_ID = "com.example.outdoorphotoassistant"` 改成
   `BUNDLE_ID = "com.你的名字拼音.outdoorphoto"`（全小写、不含特殊字符）。
2. 仓库里没有 Python 环境也能改：直接改 `OutdoorPhotoAssistant.xcodeproj/project.pbxproj`，
   搜索 `PRODUCT_BUNDLE_IDENTIFIER`（共 2 处，Debug/Release 各一），改成同一个新值。
3. 重新 Run workflow，下载新 IPA。

**改法 B（在 Sideloadly 里改）**
Sideloadly 的 `Bundle ID` 输入框里直接填一个新 ID（例如 `com.yourname.outdoorphoto`），它会用这个 ID 重签。

### 2.3 签名安装

1. 打开 Sideloadly，iPhone 连上后会自动识别。
2. 把解压出的 `OutdoorPhotoAssistant-unsigned.ipa` 拖进 **IPA** 框。
3. **Apple ID** 填你的账号；如果用新 ID，勾选并填 **Bundle ID**。
4. 点 **Start**，输入 Apple ID 密码（开启了两步验证的话，Apple ID 需要生成一个**App 专用密码**，
   在 appleid.apple.com → 登录与安全 → App 专用密码 生成，用这个密码代替账号密码）。
5. 成功后手机会自动安装。

### 2.4 iPhone 上打开前必做

1. **开发者模式**：设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机 → 再次确认。
   （iOS 16 之后自签名 App 必须开这个，否则点开就闪退/无法启动。）
2. **信任证书**：设置 → 通用 → VPN 与设备管理 → 开发者 App → 选中你的 Apple ID → 信任。
3. 打开 App，按提示允许：相机、相册（读/写）、定位（使用期间）、运动与健身。

### 2.5 7 天到期怎么办

免费账号签名有效期为 7 天。到期后 App 打不开，用同样的步骤**重新签名安装一次**即可（会覆盖旧版本，照片不受影响）。
想一劳永逸：用 AltStore（同一 Wi-Fi 下自动续签），或买 Apple Developer 账号（1 年）。

---

## 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| Sideloadly 报 `Unable to connect to device` | 装 Apple Devices/iTunes；换 USB 口；iPhone 上点「信任」；关闭 VPN 后重试 |
| 报 `Invalid Bundle ID` / `Failed to sign` | Bundle ID 冲突或含非法字符。换一个全新 ID（只含小写字母、数字、点） |
| 报 `Your Apple ID is not a developer account` | 免费账号也能签名，但需先在 <https://developer.apple.com/account> 用同一个 Apple ID 登录一次并同意协议 |
| 安装成功但点开闪退 | 90% 是没开**开发者模式**；其次是没有信任证书；再次检查 iOS 版本是否低于 17.6 |
| 提示「App 未受信任」 | 设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID |
| 相机黑屏 | 设置里检查相机权限；或重启 App；iOS 26 上首次调用需要权限弹窗被允许 |
| 拍照没有照片 | 检查相册写入权限；App 内会弹出保存失败原因（红条/底部提示） |
| 深度/3D 人像始终「未生成」 | 机型不支持 Portrait Effects Matte（只有 iPhone XS/XR 之后部分机型 + 前置原深感/后置双摄支持），属于正常降级 |
| 用 Xcode 真机调试报 signing 错 | 在 target 的 *Signing & Capabilities* 选自己的 Team，并把 Bundle ID 改唯一 |

---

## 验收清单（装好后按顺序试）

1. 允许权限后取景正常、画面不卡（老机型可接受 30fps）。
2. 点画面不同位置，对焦框应跟着点击位置（不会跑到别处）。
3. 按快门→相册出现**2 张**：原片 + 成片（若关闭「存原片」则只有成片）。
4. 切到 0.5×：画面视野明显变广（黑屏一闪属正常，约 0.1–0.3 s）。
5. 人物场景：出现主体框，构图分明显提高；拍完进入复盘页，拖动美颜滑杆预览会刷新。
6. 打开「自动拍」：构图分高且水平稳定 3 秒左右，应自动倒计时并拍摄一次（这是原版永远触发不了的逻辑）。
7. 打开「高清」：拍出的成片分辨率提升（设置里可关掉以省内存）。
8. 相册里查看原片信息：应保留拍摄时间/机型等 EXIF（原版会丢）。
9. 切到后台再回来：相机应自动恢复，不黑屏。
10. 弱光/高温：App 不应崩溃（档位降级到「轻量」）。
