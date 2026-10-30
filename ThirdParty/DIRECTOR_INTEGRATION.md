# 导演开源代码实际接入

## Smartcrop
源仓库：https://github.com/jwagner/smartcrop.js
源码：smartcrop.js；本包同目录上游快照记录完整blob SHA。
许可证：MIT，(c) 2016 Jonas Wagner。

已将 importance()/thirds() 的候选构图位置重要性算法移植到 DirectorCropImportance。
调用路径：Camera帧 → FrameAnalyzer.composeScore / DirectorEngine.evaluate → DirectorCropImportance.score → 比较当前倍率和候选倍率。
保留中心距离、边缘惩罚、可选三分强化；不引入完整JavaScript运行时，没有把Smartcrop的肤色阈值检测当作新训练模型。图像语义检测继续由Apple Vision完成。

## KalmanFilter
源仓库：https://github.com/wearereasonablepeople/KalmanFilter
源码：KalmanFilter/KalmanFilter.swift；上游blob SHA 2f62bed4c3700fd1249e6643fc152f26c80203f5。
许可证：MIT，(c) 2019 WEAREREASONABLEPEOPLE B.V.；源码头另有(c) 2016 Oleksii Dykan。

将预测/更新公式按单变量F=H=1、B=0移植成DirectorKalman，去掉泛型矩阵协议依赖。
调用路径：DirectorController.evaluate → DirectorKalman.update → 平滑以当前倍率归一化后的主体占比 → 候选构图评分 → 连续确认及冷却 → CameraService.setZoom。
这是尺寸平滑与时间连续性判断，不是人物身份识别或运动轨迹神经网络。

## NextLevel
沿用此前已实际移植的曝光、设备变焦及倍率监听；详见NextLevel/INTEGRATION.md。

两份新增库的完整MIT许可证已放入源码字符串，App设置可以展开查看；也随ThirdParty目录分发。
没有引入整个第三方SDK，没有下载摄影大模型，没有训练权重。
