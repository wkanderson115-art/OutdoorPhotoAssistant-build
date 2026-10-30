# DeepSeek + Seedream 按需修图与自有图库

本轮日期：2026-10-24。App版本1.1，构建6。本报告优先于旧报告里的离线/未接入云端/系统最近照片描述。

## 已实现的使用路径

1. 设置 → 云端图片服务 → DeepSeek / Seedream · API Key设置。
2. 分别填写DeepSeek Key和火山方舟Key，分别点保存；Key存入本机系统钥匙串。保存Key不会调用模型。
3. 用App拍照：原始照片和本地成片自动进入“我的图库”。App自有图库不需要读取系统相册权限。
4. 图库中点一张照片，选择“原片/本地成片/AI修图”中的一个版本；这个版本就是后续上传源。
5. 开启“先由DeepSeek看图给建议”，填写要求并点“获取DeepSeek建议”。程序发送真实图片副本，返回场景、优点、问题、建议、应保留内容及完整修图指令。
6. 查看后点“采用建议到修图要求”，可继续修改文字。这个操作本身不调用API。
7. 只有再点“用Seedream修这张”才调用Seedream。程序下载完整结果并另存AI版本，不覆盖原片。
8. 不需要DeepSeek时关闭本张照片的选项，直接填写Seedream修图要求即可。
9. 查看版本菜单可切换原片/本地成片/AI结果；需要时手动导出选中版本到系统相册。

DeepSeek建议不等于自动修图；没有每拍一张、打开图库、切换照片、保存Key或打开设置时的付费请求。

## 两家接口与默认模型

| 服务 | 请求地址 | 默认模型 |
| --- | --- | --- |
| DeepSeek看图 | https://api.deepseek.com/chat/completions | deepseek-flash |
| Seedream编辑 | https://ark.cn-beijing.volces.com/api/v3/images/generations | doubao-seedream-5-0-pro-260628 |

DeepSeek使用image_url中的JPEG Base64和JSON建议输出，max_tokens为1800；不会用不支持图片的文本模型冒充看图。Seedream传入选中的原图副本与编辑提示，默认2K、JPEG、返回URL，水印参数为true。也处理接口可能返回的Base64图片。设置中可改Seedream模型/接入点ID，以匹配你的方舟权限。

没有填入任何真实Key，没有硬编码共享Key。DeepSeek和火山方舟是两套凭证，不能共用。自用版采用手机直连官方接口；Key不写入UserDefaults、工程、图片或任务记录。返回图片的下载请求不携带API Key，接口请求拒绝HTTP重定向。

官方契约参考：
https://api-docs.deepseek.com/zh-cn/guides/vision/
https://api-docs.deepseek.com/zh-cn/guides/json_mode/
https://www.volcengine.com/docs/ark/image-generation-api
https://docs.volcengine.com/docs/ark/seedream-5-0-pro?lang=zh

## 费用与重复调用控制

- 两步手动决定，建议成功后不自动调用Seedream。
- 相同照片版本、相同要求的DeepSeek建议复用本机记录；只有点“重新看图分析”才强制再次调用。
- 相同照片版本、相同修图提示、相同模型已有Seedream结果时直接复用；需要变体时有单独的“重新生成新版本”按钮。
- 每张照片有持久化任务记录，同一张照片已有任务运行时不能发起第二个任务；界面也会禁用重复点击和源版本切换。
- 应用层没有自动重试模型请求。401、429、超时、无效JSON或下载失败均显示错误。
- Seedream返回的生成链接先持久化，再开始下载。若下载失败或App被中断，可以在任务记录点“仅重试下载”，这条路径不调用生图接口。
- 重启后，未完成的任务标为中断，不自动重放。服务端已收到的请求仍可能计费；停止等待不等于取消服务端生成。
- 关闭照片详情不会主动重发任务；前台任务可以继续并存回原照片。未实现系统后台上传会话，iOS挂起或杀进程时不保证任务完成。
- 任务记录是调用尝试和状态记录，不是两家平台的最终计费账单。

## 图库与原片

原来的图库是系统相册最近30张。现在改为Application Support中的App自有图库，仅包含本软件拍摄记录及版本。每张照片独立目录：原始字节、缩略图、本地/AI版本、建议、任务状态和原子写入的record.json。修订号避免异步旧快照覆盖新记录。

拍照与拍后本地优化使用同一个photoID，不再因保存复盘结果而生成另一张无关照片记录。原片保留原始EXIF和深度信息；上传时另生成去掉EXIF/GPS、方向归一化的JPEG副本：看图最长边1280，修图最长边3072。Seedream输出默认2K，因此不承诺保留原片全部像素或逐像素一致。

系统相册导出独立于App图库，默认关闭自动导出；可以设置拍照后同时导出，也可以在图库单张手动导出。拒绝系统相册权限不会阻止App图库保存。之前版本已经写入系统相册的照片仍在系统相册，本版不会猜测或自动搬入这些旧照片。

## 新增源码

- Core/Cloud/CloudAPI.swift：两家请求构建、结构化建议解析、错误处理和结果下载。
- Core/Cloud/CloudConfiguration.swift：固定官方地址所需配置和分服务Keychain存取。
- Core/Storage/AppPhotoStore.swift：自有图库持久化、版本、缩略图、建议、任务和下载恢复。
- Features/Gallery/GalleryView.swift：图库、照片版本、可选建议、手动编辑、结果与任务记录。
- Features/Cloud/CloudAPISettingsView.swift：两处Key输入与模型设置。
- PhotoLibraryService.swift改为App图库服务，保留独立系统相册导出能力。

隐私说明同步到App设置，PrivacyInfo加入按需上传照片的功能用途声明。发布前仍需按实际账号服务和分发方式核对隐私资料。

## 验证状态（请区分）

已执行并通过：
- 工程结构、24个Swift源文件的Sources引用、plist、资源、工作流静态检查。
- 24个App Swift文件的语法解析；3个测试Swift文件的语法解析。
- 无拍照自动云端调用、统一照片ID、Keychain、缓存、下载恢复及可移植工程路径的源码检查。
- ZIP完整性检查。

已准备、未执行：
- tests/cloud/main.swift：用URLProtocol模拟服务，检查真实图片字段、分服务地址、缺Key、结构化建议解析、一次建议不继续生图、单次生成、429不重试、错误中的Key隐藏、无效建议拒绝。已接入GitHub Actions。
- 先前的导演决策及快门测试保留。

未执行：
- 当前环境没有swiftc/Xcode/iOS SDK，所以没有运行Swift行为测试、类型检查或Debug/Release构建。
- 没有用户API Key，没有真实鉴权、余额、模型权限、DeepSeek识图或Seedream出图测试。
- 没有iPhone视觉布局、Keychain、图库文件和相册导出真机测试。

这是可继续在Xcode或已有GitHub Actions构建的源码工程，不是已签名安装包。不能把语法检查通过称为已连通真实API。

## 真机验收

1. 不填Key连续拍3张、打开图库和设置：应出现3条本机照片记录，网络代理确认没有模型请求。
2. 拒绝相册权限再拍照：App图库保存正常；只有导出失败。
3. 设置分别保存两家Key，重启后仍可读取；空值保存能删除对应Key；操作日志及record.json不能出现Key。
4. 选一张有明确内容的照片调用DeepSeek，检查建议针对该图；建议返回后不得自动调用Seedream。
5. 同图同要求再次获取建议：应使用缓存；“重新分析”才有第二次请求。
6. 采用或编辑建议，点Seedream；检查仅1次生成请求，AI版本返回图库，原片字节未改变。
7. 关闭DeepSeek选项后直接修图：应无DeepSeek请求。
8. 连点、返回再进照片、切版本、断网、401、429、超时：无隐式循环重试或重复付费请求。
9. Seedream出图后人为断开下载网络，再点“仅重试下载”：应只请求已有图片URL，没有新的generations POST。
10. 任务中杀进程后重开：应标为中断，不自动重发；已有建议和AI版本仍可查看。
11. 比较原片、本地和AI版本：方向正确、比例无强制裁切；上传副本不含GPS。
12. 小屏、动态字体和VoiceOver检查照片、Key输入及按需按钮可用。
