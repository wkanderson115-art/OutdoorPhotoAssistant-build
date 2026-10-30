# 不购买域名：部署到 Render

当前源码已包含一套适用于Render的配置，尚未在真实Render账号执行部署。它会创建**付费资源：1个2GB内存的Web Service，以及5GB持久磁盘**，费用以创建页面当前报价为准；DeepSeek和Seedream调用费用另计。先审核配置及费用，再在平台确认创建。

## 1. 把工程放到自己的 GitHub 私有仓库

解压最新版工程包，打开里面的 `OutdoorPhotoAssistant` 文件夹。把**这个文件夹内的内容**上传到仓库根目录，不要只上传ZIP，也不要再套一层文件夹。应能直接看到：

- `render.yaml`
- `.python-version`
- `server/`
- `OutdoorPhotoAssistant/`（iOS源码）
- `OutdoorPhotoAssistant.xcodeproj/`

可以使用GitHub Desktop提交并发布私有仓库；也可使用GitHub网页上传。仅用新建的私有仓库，不要误覆盖其他项目。真实`.env`、Key、数据库都不能提交。

## 2. 在Render创建Blueprint

访问 https://dashboard.render.com/ ，登录后连接GitHub，授权访问上一步的私有仓库。

选择 **New → Blueprint**，选择该仓库和分支，配置文件路径为 `render.yaml`。检查资源列表是一个 `outdoor-photo-api` Web Service，磁盘挂载路径 `/var/data`、容量5GB；实例数1。

配置采用Python原生运行，不需要另外创建Docker服务，也不需要另建Background Worker。`launch.py`会同时启动API和任务进程；任一进程异常退出就停止另一进程，让平台统一重启。持久盘仅供这一服务使用。Python由`.python-version`选择3.12系列。

若不使用Blueprint，手动New → Web Service的对应设置如下：

| 字段 | 值 |
|---|---|
| Language / Runtime | Python |
| Root Directory | `server` |
| Build Command | `pip install -r requirements.txt` |
| Start Command | `python launch.py` |
| Health Check Path | `/health` |
| Instance | 付费，建议2GB内存，实例数1 |
| Disk Mount Path | `/var/data` |
| Disk Size | 5GB |

不要使用免费服务承载这版图库：需要持久磁盘保存任务和图片，免费实例不支持该配置。2GB为当前图像解码、Base64与网络响应的保守试运行配置，并非已经完成压力测试的容量结论。

## 3. 仅在Render填写环境变量

创建Blueprint时，会提示填写以下四项：

| 变量 | 填什么 |
|---|---|
| `DEEPSEEK_API_KEY` | 自己DeepSeek开放平台的API Key |
| `SEEDREAM_API_KEY` | 自己火山方舟账号的API Key，需具备对应Seedream模型权限 |
| `APPLE_CLIENT_ID` | iOS工程实际使用的Bundle Identifier，必须与Apple登录签名一致 |
| `ALLOWED_APPLE_SUBS` | 允许使用服务的Apple账号标识，多个用英文逗号分开 |

最后两项不是API Key。Apple账号标识是原生`ASAuthorizationAppleIDCredential.user`，不是Apple邮箱、密码或Bundle ID。允许列表为空会拒绝所有云端登录，服务不会开放匿名调用。

测试时由开发者在受控Xcode调试流程获取自己的账号标识：在 `CloudAPISettingsView.completeLogin` 中，成功取得 `apple` 凭证后、提交后端前设置断点，调试器查看 `apple.user`，填入Render的`ALLOWED_APPLE_SUBS`后保存配置。不要用客户端传来的user字段替代服务端签名验证，也不要在生产日志打印Apple身份token。

已经写入配置的非秘密项：

- `DATABASE_PATH=/var/data/jobs.sqlite3`
- `USER_DAILY_LIMIT=10`
- `GLOBAL_DAILY_LIMIT=200`

服务端模型默认DeepSeek `deepseek-flash`、Seedream `doubao-seedream-5-0-pro-260628`；可按账号实际开通情况在Render增加`DEEPSEEK_MODEL` / `SEEDREAM_MODEL`，不要在App里填Key。Key只填平台环境变量，不发到聊天、GitHub或App。

## 4. 获取平台自带HTTPS地址

核对费用并确认创建，等待Build和Deploy完成。平台会分配类似 `https://你的服务名.onrender.com` 的地址，实际以控制台显示为准，不用另买域名。

打开这个实际地址后加 `/health`，正常应显示 `{"status":"ok"}`。这只说明后端HTTP服务已启动，**不能证明Apple登录、供应商权限、模型调用、存储恢复或图片质量都通过**。

可在服务设置关闭自动部署、改为人工部署，避免提交与本服务无关的代码时中断正在进行的图片任务。带盘服务在重新部署时会有短暂停机；已在上游执行但响应未落盘的任务可能标记unknown，不会自动重新生成。

## 5. 连接iOS App

在Apple Developer为实际Bundle ID启用Sign in with Apple，更新签名和Provisioning Profile；工程已有所需entitlements。

Xcode中选择App Target → Build Settings，搜索 `PHOTO_BACKEND_URL`，把Debug和Release都设为上一步的真实HTTPS原点：只填 `https://实际服务名.onrender.com`，不加`/health`、`/v1`或查询参数。这一地址属于公开配置，不能也不需要把它当成密钥隐藏。

重新编译安装App → 设置 → 云端服务 → Apple登录。此时不再填写DeepSeek/Seedream的Key。未加入允许列表会提示账号尚未获准。

## 6. 逐项验证

先用一张非敏感照片，并把每日额度调小：

1. 拍照后照片在本机图库出现，未自动上传。
2. 点“获取建议”才上传，成功后显示建议，未自动精修。
3. 采用建议不触发模型请求，点精修才生成。
4. 原片与AI版本均可查看，导出保存的是当前显示版本。
5. 下载中断后继续原任务，核对平台实际调用次数未多一次。
6. 服务器重启后仍能查询已完成任务、下载未过期结果，超过24小时的云端结果不可再下载。
7. 换未经允许账号不可登录；其他账号不能取走本账号图片。

当前已在本地执行22项后端及进程监督测试，没有实际部署Render、使用真实Apple账号或调用真实付费API。以以上联调通过作为部署完成依据。

官方资料（2026-10-24核对）：

- https://render.com/docs/web-services
- https://render.com/docs/disks
- https://render.com/docs/blueprint-spec
- https://render.com/docs/python-version
- https://render.com/pricing
