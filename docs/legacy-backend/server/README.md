# 图片服务后端（需部署后才能联网使用）

App 已切换为此服务，不再持有或直连 DeepSeek / Seedream 的供应商 Key。把界面字段隐藏、Keychain 存 Key 或混淆代码均不能保护发行包里的共享供应商密钥，因此旧的两个 Key 输入框已移除。新版使用 Apple 登录换取短期、可撤销的个人会话；会话存本机 Keychain。网络接口地址可以被观察，安全依赖鉴权和服务端密钥，而不是地址保密。

## 无需购买域名的推荐部署

项目根目录已附 `render.yaml`，使用Render分配的HTTPS地址。操作看根目录 `RENDER_DEPLOY.md`。这是一个付费Web Service，内部运行API和worker两个进程，共享一块持久盘；不要在Render另建worker服务共享SQLite（平台不支持跨服务共享磁盘）。API子进程不接收供应商Key环境变量。原来的Compose配置继续用于自有服务器。

## 自有服务器部署

1. 在 Apple Developer 为实际 Bundle ID 启用 Sign in with Apple，更新描述文件和签名；工程已添加 entitlements。`com.example...` 仅是占位标识，必须更换。
2. 复制 `.env.example` 为服务器上的 `.env`，只在那里填写两家供应商 Key、实际 `APPLE_CLIENT_ID` 和获准账号的 Apple `sub`（与原生 `ASAuthorizationAppleIDCredential.user` 对应）。不要把真实 `.env` 放进源码、App、截图、聊天或日志。允许列表为空时拒绝所有账号。测试账号的标识由开发者从其受控的 Apple 登录调试流程取得，不能信任客户端自行提交的 user 字段。
3. `docker compose up --build -d`，包含 API 和一个独立 worker，持久卷为 `/data`。API 容器不注入供应商 Key，worker 才有 Key。SQLite 方案适合单服务器试运行；多机扩容需改为共享数据库和队列，不能复制各自独立的 SQLite。启动第二个 worker 会因独占锁退出。
4. 在自己的域名配置 HTTPS 反向代理至 `127.0.0.1:8080`。例如 Caddy 使用 `Caddyfile.example`（替换域名）。配置代理上传限制16MiB、请求限流和 HTTPS；不要记录 Authorization、请求体、图片或模型返回。端口8080只监听回环地址。数据库卷和备份需做访问控制及磁盘加密，不要公开挂载。
5. Xcode 的 `PHOTO_BACKEND_URL` 填写 HTTPS 域名原点（无路径、无尾部参数，例如 `https://photos.your-domain.com`）。这是公开配置，不是密钥。不要在 App 填写供应商 Key。Debug、Release 都需设置，或在构建命令中提供该 setting。
6. 验证 `/health` 后，在真实 iPhone 登录，用一张非敏感测试图检查：建议、采用建议、精修、退出后再登录取回、网络断开后继续、图库导出。检查两家平台实际模型权限和账单。

没有服务器域名、Apple 签名账号及真实供应商凭证时，源码可以交付，但不能称为已上线、已连通或可安装成品；未配置时本地拍照与图库继续工作。

## 上传、任务和下载

- 本机 ImageIO 按方向缩小：建议最长边1280、编辑3072、JPEG质量0.9，最多15MiB；保留原始比例，不默认裁切，移除EXIF/GPS，原片不动。
- `POST /v1/jobs`：multipart 的 `kind`（advice/edit）、`instruction`、`image`；Authorization 为登录会话，`Idempotency-Key` 为落盘的本地 UUID。同一编号和内容只占一条任务和一次额度；同号换图/要求返回409。
- API 在事务中写入 SQLite 后立即202，独立 worker 执行单次供应商请求。DeepSeek使用真实照片及结构化 JSON，建议最多3项，不自动调用Seedream。Seedream由服务端强制加自然精修约束；模型由服务端环境变量决定，客户端不能提供任意模型/上游地址/Key。
- `GET /v1/jobs/{id}` 查询排队、处理、完成、不确定、过期。App每3秒查询，等待超时或退出可继续原任务。若确定404，使用同一UUID补传；普通按钮优先取回未完成的匹配任务。用户明确点“新建任务重新生成”才新建UUID，可能再次计费。
- Seedream选择 `b64_json`，后端验证格式和尺寸并保存原始输出字节，保留水印/来源标记，不依赖公开临时图片URL，不下载用户指定URL。供应商结果不会直接暴露给App。
- `GET /v1/jobs/{id}/result`：仅所属账号可下载的 image/jpeg，限制30MiB/2400万像素。App下载到临时文件、验证、原子写入图库为新版本，不覆盖原片；“导出当前版本”按实际显示的原片或AI成片导出。
- 传输失败可重新下载整个结果；当前没有HTTP分段断点续传或iOS后台传输会话。离开前台可能暂停等待，重新进入用原任务恢复。停止等待不等于撤销已提交的付费请求。
- worker曾处于running的任务在崩溃重启后标记unknown，绝不自动重新生成。上游没有提供可靠对账机制时，超时后的“到底是否已计费”无法凭客户端保证，UI明确提示。切勿自动重试付费POST。

## 限制和隐私

- Apple签名、issuer、audience、有效期、nonce校验；challenge单次使用；服务端会话24小时有效，退出立即撤销；无匿名付费调用、无App内共享万能密钥。
- 默认每账号每日10次、全服务每日200次，每账号最多2个活动任务，全队列最多100个；建议与编辑分别计一次。额度在入队时保守预占，失败不自动退还，避免重复请求套用额度。可在服务器调整。
- 图片和建议在24小时后无法取回，由worker清理；成功后上传副本立即删除。保留最小任务编号、归属哈希和指纹，作为防重复提交记录，不把过期编号重新变成付费任务。结果已下载到App则长期保存在本机图库。
- 当前为获准账号试运行版本。公开上架前需部署正式隐私政策、完善云端数据删除/账号生命周期及运营审核流程，并按实际上架要求核对披露；本工程不声称已经通过App Store审核。
- 不记录/回传上游原始错误和密钥，返回通用错误。API无开放代理、无CORS跨站放行、无自动跳转、无任意结果URL抓取。

## 已验证和待验证

`python -m unittest discover -s server/tests -v`：20项模拟测试通过，覆盖鉴权、真实RSA签名校验（测试钥匙）、nonce重放、账号隔离、幂等、额度、队列恢复、模型请求契约、下载、脱敏与过期。没有调用真实付费API；Apple JWKS在线获取、Apple真实登录、真实模型响应、代理部署、手机网络及Xcode编译尚待实测。
