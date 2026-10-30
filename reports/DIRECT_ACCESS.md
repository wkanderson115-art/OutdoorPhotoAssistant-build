# 切回第一种：App直接调用模型（2026-10-24）

按用户取消后端托管费用的要求，恢复个人Key直连。

已修改：CloudAPI.swift恢复DeepSeek真实图片JSON请求和Seedream图片编辑请求；CloudConfiguration.swift恢复独立Keychain条目；CloudAPISettingsView改回两个隐藏输入位置，保存后清空而不回填Key；Gallery工作流移除后端上传、Apple登录与轮询；App入口仅清理旧后端会话。Xcode和工程生成器去掉后端地址、Apple登录entitlements，构建号8。CI只保留iOS工程/模拟契约测试与构建任务。

上传沿用ImageIO去元数据副本；Seedream返回URL先落盘再下载；下载不带Key，只重试已有链接；cloudJobID防止同任务重复保存图库版本。对未完成且无结果链接的请求采取保守阻止普通重发，明确重新分析/新建任务才另发付费请求。模型请求不自动重试。缓存优先，逐张选择，不自动逐张P图。

保留自然-v1策略、CainCamera公式与实时预览、连续/自动变焦、AI导演、本机图库、现有Figma同步界面。没有把相机整体回退到旧版。

旧server与Render配置归档至docs/legacy-backend，render.yaml改为.disabled，没有在用户外部平台创建、删除或修改任何云服务。当前方案没有托管月租，但供应商模型费用仍按其账单计收。

验证：工程和Swift语法静态检查通过；直连模拟行为测试已更新但未执行（环境无swiftc/Xcode）；真实模型、钥匙串和真机拍照验证未做。历史后端22项测试结果不代表当前直连版运行测试通过。

安全边界：Keychain和SecureField减少日常暴露，不等于绝对隐藏API Key；端侧直连没有服务端密钥隔离与可靠任务队列。终止等待不撤销上游任务，链接过期或超时可能无法取回结果。文档不承诺绕过模型收费或平台地区限制。

官方接口已重新核对：
- https://api-docs.deepseek.com/guides/vision/
- https://docs.volcengine.com/docs/ark/image-generation-api?lang=en
