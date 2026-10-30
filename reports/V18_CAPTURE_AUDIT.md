# V18 拍摄模块审计（第一轮）

审计对象：`CaptureView` / `CameraService` / `DirectorEngine` / `DirectorVision` / `FrameAnalyzer` / `AdaptiveCameraEngine` / `SmartShutterEngine` / `PhotoPostProcessor` / `PhotoFilter` / `ColorGrade` / `PortraitBeautyEngine` / `CompositionOverlay` / `DepthPortraitProcessor` / `MotionService` / `LocationService`，合计 16 个文件约 4,000 行。

审计方式：静态阅读 + 交叉引用检查（这台机器没有 Xcode，不能编译、不能真机跑）。

## 一、结论先说

拍摄模块**工程底子是好的**（独立 sessionQueue、权限状态机、导演决策、连拍评分都在），但它和精修模块之间**没有任何数据交接**，而且**保存出片时已经套过一层美颜 + 调色 + 滤镜**——这两点是当前产品级最大的风险，比任何单个 bug 都重要。

## 二、做得对的部分（保留）

1. `CameraService` 用独立 `sessionQueue`，`startRunning/stopRunning` 都在队列里做（`CameraService.swift:27、136–163`），没有在主线程开 session 这种典型卡死写法。
2. 权限走 `authorizationStatus` + `requestAccess` 状态机（`146–163`），不是硬要权限。
3. 有 `wantsRunning` 标志位收敛启停，避免前后台切换时重复 start。
4. 导演/构图/快门评分拆成了独立小文件（`DirectorEngine` 451 行、`FrameScoring` 62 行、`SmartShutterEngine` 41 行），职责清晰。
5. 景深人像单独一个 `DepthPortraitProcessor`（45 行），没有塞进相机主类。

## 三、必须修的问题（按严重度）

### P0-1 拍摄端与精修端**重复调色/重复美颜**
`CaptureView.swift:571` → `PhotoPostProcessor.render(original:options:)`，而 `PhotoPostProcessor` 内部会依次套 `PortraitBeautyEngine`（856 行，独立的一套磨皮/美白）、`ColorGrade`（342 行）、`PhotoFilter`。也就是说：
- 存进相册的 JPEG 已经磨过皮、调过色、套过滤镜；
- 用户在「影楼精修台」再跑一遍，等于**二次磨皮 + 二次调色 + LUT 叠加**，肤色会二次偏移、毛孔被抹两遍、饱和度过冲。

修法（建议 B 方案）：
- 拍摄端同时写两份：`*_flat.jpg`（只做降噪/几何/EXIF，不套 grade/beauty）与 `*_graded.jpg`（所见即所得预览用）；
- 在 EXIF/自定义元数据里写 `OPA_variant=flat|graded`、`OPA_grade=自然/电影/...`；
- 导入精修批次时只吃 `flat`，并在 UI 标注「本次精修基于未调色底片」。
- 改动面：`PhotoPostProcessor.render` 加一个 `outputVariant` 参数 + `CameraService` 保存路径 + 批次导入筛选（约 1 周）。

### P0-2 拍摄 → 精修**零交接**
全工程 grep：`ShootAnchor` / `RetouchAdjustments` / `RetouchBatchRunner` 在拍摄侧**没有任何引用**。后果：
- 拍完不会自动进批次，得手动去精修台再选一次；
- 拍摄时已经知道的场景分类、曝光、白平衡、连拍最优帧，精修端全部要重新算一遍（浪费一次分析，也让套系锚点失去“拍摄时就统一”的机会）。

修法：拍完写一份 sidecar（`<uuid>.json`）：场景标签 + 置信度、曝光/白平衡、连拍评分、`flat` 文件名。批次导入时优先读 sidecar，锚点直接用拍摄时的曝光/白平衡做初值（约 1 周）。

### P0-3 `as!` 强转有崩溃面
`CameraService.swift:857`：`layer as! AVCaptureVideoPreviewLayer`。视图层级一旦变化（SwiftUI 重组、被别的容器包裹）就是崩溃。改成 `guard let layer = view.layer as? AVCaptureVideoPreviewLayer else { return }`。

### P1-1 预览美颜与交付观感不一致
`PortraitBeautyEngine` 是实时预览用的美颜，参数与精修引擎是两套。用户在取景框看到的皮肤 ≠ 交付的样子。修法：预览美颜只做“轻度预览”，并在精修台提供“按预览观感对齐”的预设（或者干脆预览不美颜，交给精修）。

### P1-2 保存路径可能在主线程做重活
`CaptureView.swift:571` 在视图方法里同步调用 `PhotoPostProcessor.render`（24MP 全流水线）。需要确认是否已在后台队列；若在主线程会造成拍照后卡顿/掉帧。修法：`render` 移到 `Task.detached`，UI 只收结果。

### P1-3 缺少 48MP/RAW 路径
没有 `CIRAWFilter`、没有 `AVCapturePhotoOutput` 的高像素会话预设处理。商业客户迟早要。

## 四、建议的实施顺序

| 顺序 | 事项 | 工作量 | 依赖 |
| --- | --- | --- | --- |
| 1 | P0-3 `as!` 改安全转换 | 10 分钟 | 无 |
| 2 | P0-1 flat/graded 双写 + 元数据标记 | 约 1 周 | 需要先定精修批次导入筛选 |
| 3 | P0-2 拍摄 sidecar + 批次导入读 sidecar | 约 1 周 | 依赖 P0-1 的文件命名 |
| 4 | P1-2 保存渲染移后台 | 半天 | 无 |
| 5 | P1-1 预览美颜与精修对齐 | 3–5 天 | 需要真实客片对比 |
| 6 | P1-3 RAW/48MP | 1–2 周 | 需要真机 |

## 五、审计范围的诚实说明

- 本轮只做了**静态阅读和交叉引用**，没有编译、没有真机、没有跑过任何拍摄路径；`DirectorEngine`/`FrameAnalyzer` 的算法正确性（构图/曝光决策是否符合预期）需要用真实场景样张验证，不在本轮结论内。
- 上面每条都标了文件与行号，你可以直接核对；P0-1 的“二次调色”是结构性事实（调用链在代码里），不是推断。
