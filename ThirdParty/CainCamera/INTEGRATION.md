# CainCamera 实际接入记录

来源：https://github.com/CainKernel/CainCamera ，Apache-2.0，Copyright 2018 cain.huang@outlook.com。

本次移植的上游文件及读取到的blob SHA：

- `filterlibrary/src/main/assets/shader/beauty/fragment_beauty_highpass.glsl`，`70e95bb18bf10e734823688efa03cd3f005aec7b`。
- `filterlibrary/src/main/assets/shader/beauty/fragment_beauty_adjust.glsl`，`676627ac290d48a42f5c7e351db1f6613613c77c`。
- 渲染阶段参考 `filterlibrary/src/main/java/com/cgfay/filter/glfilter/beauty/GLImageBeautyFilter.java`，`cbb19b6cf9d06a2aad07feb3532b6bcac7988d57`。

修改：GLSL纹理采样转Core Image CIColorKernel输入；保留48倍平方高通、蓝通道保护、细节相关混合公式；新增Vision面部遮罩、眼眉唇保护、多人最多6张脸、磨皮上限0.30；不默认瘦脸/大眼/增白。Core Image内核不可用时保留原图，不虚称处理成功。

实际调用：CameraService的视频帧 -> RealtimePreviewProcessor -> PortraitBeautyEngine.processCI -> CainBeautyKernels；拍照 -> PhotoPostProcessor -> PortraitBeautyEngine -> 同一公式。滤镜与调色共用PhotoPostProcessor.applyColor。预览最长边1280/最高15fps，一帧在处理时丢弃新帧，严重热状态降到8fps；原尺寸照片独立处理。

没有接入Android Java/OpenGLES相机管理、Face++、商业美颜SDK、动态贴纸资源或未知素材。未进行iPhone帧率、GPU内核编译、肤质及颜色实测。CIColorKernel源码初始化是旧Core Image接口，需Xcode和设备验证，未来可改Metal内核；本包不声称已经验证其设备兼容性。

完整许可证随本目录及App设置内置，移植代码文件已注明修改。
