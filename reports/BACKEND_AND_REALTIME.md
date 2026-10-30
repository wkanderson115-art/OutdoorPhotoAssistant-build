# 截图方案判断与本次修改

截图1：本地准备副本→自己后端→供应商→保存结果的逻辑可行。getUserMedia/Canvas是网页API，本项目为iOS原生，保持AVFoundation和ImageIO。自动压缩不等于自动裁切，不改变原始画面比例。隐藏Key不是隐藏输入框；发行App无法安全藏共享供应商Key，因此已移到server环境变量。

截图2：CainCamera是Android学习项目，有实时分阶段美颜、滤镜及独立强度控制。已核对实际GLImageBeautyFilter及两段GLSL源码，移植数学公式到Core Image，并接入真实帧链路与拍后链路。没有声称直接安装了Android库或接入其Face++依赖。

截图3：商业SDK和代理SDK不是实现这一流程的必需项。当前采用iOS原生图像链路+自建持久队列和后端代理，避免未经验证的SDK名称、授权和平台兼容性。服务端用Base64接收Seedream结果，App从鉴权接口下载，降低临时公开链接过期及URL抓取风险。

修改路径：Core/Cloud/CloudAPI.swift与CloudConfiguration.swift、Features/Cloud/CloudAPISettingsView.swift、Features/Gallery/GalleryView.swift、Core/Storage/AppPhotoStore.swift、Core/Camera/CameraService.swift、Core/Analysis/PortraitBeautyEngine.swift与PhotoPostProcessor.swift、CaptureView/SettingsView、App入口、entitlements、Info/Privacy、工程生成器和CI。新增server部署工程和20项可执行模拟测试。

服务端测试：20项全部通过。App工程/Swift静态检查通过。未执行Swift行为测试、Xcode构建、真实Apple登录、真实API、服务器公网部署或iPhone画面验证。依赖注入测试验证请求/状态逻辑，不能证明供应商账号权限、计费或真实出图质量。

本次不会把真实供应商Key写入客户端。服务地址是公开配置，可被逆向看到；保护目标是密钥、用户照片和付费调用权限，不能承诺网络接口地址本身不可见。后端仍需运营者配置HTTPS、Apple标识/允许账号和两家Key；当前未部署，云端尚不可用。
