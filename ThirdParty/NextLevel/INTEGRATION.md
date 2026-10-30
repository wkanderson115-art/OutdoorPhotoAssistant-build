# NextLevel 源码移植记录

来源：https://github.com/NextLevel/NextLevel/blob/main/Sources/NextLevel.swift
源码blob SHA：fbf90185f15c26709d76e6c53816b68fd622b86e
许可证：MIT，全文保存在同目录LICENSE；App设置内也可展开查看。

## 已接入运行路径

| 上游代码 | 本工程适配位置 | 实际调用 |
| --- | --- | --- |
| expose(withTargetBias:force:completionHandler:) | AdaptiveCameraEngine.swift / NextLevelDeviceControls.expose | CameraService.applyExposureCompensation |
| videoZoomFactor setter | AdaptiveCameraEngine.swift / NextLevelDeviceControls.zoom | CameraService.applyDeviceZoom |
| addCaptureDeviceObservers 中videoZoomFactor KVO | CameraService.observeZoom | 安装摄像头及恢复旧镜头时注册，移除输入及释放时销毁 |

移植保留了原始曝光调整保护、范围夹紧、设备锁、倍率监听结构。适配包括显式传入设备、defer释放锁、错误与成功返回、平滑变焦、动态可用上限及4K/照片会话兼容的现有镜头换算。删除上游对NextLevel实例、delegate和clamped扩展的依赖。上游摘录在UPSTREAM_EXCERPTS.txt，实际编译的是现有Swift文件内的适配代码。

没有引入整个NextLevel SDK，没有修改AVCaptureSession归属；GPUImage3仍未接入。此记录替代前一轮报告里“未复制第三方代码”的状态说明。

验证：静态工程检查及18个Swift源码语法解析通过；无Xcode/iOS SDK，未执行类型检查、编译或真机测试。需要在Mac/GitHub Actions构建，再验证持续变焦、前后摄切换、曝光变化、后台恢复。
