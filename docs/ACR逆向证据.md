# ACR 逆向证据（Camera Raw 18.7）

目标：`C:\Program Files\Common Files\Adobe\Plug-Ins\CC\File Formats\Camera Raw.8bi`

| 项 | 值 |
|---|---|
| 文件大小 | 245,288,936 字节 |
| MD5 | `EF8C6AE58B1C99ECDCDB6715A941A1E7` |
| 架构 | PE32+ x64，ImageBase `0x4FAD0000` |
| 版本 | Camera Raw 18.7（PDB 路径 `F:\Builds\ws\r18.7\win64\acr\camera_raw\...`） |
| 加壳 | 无（`.text` 46.9MB，熵 6.64） |

## 1. 静态结构统计

| 证据 | 数量 | 提取方式 |
|---|---|---|
| RTTI 类名 | 7,904 | `acr_deep.py` 扫 `.?AV/.?AU` |
| `cr_stage_*` 类型描述符 | 354 | 同上，筛 `. ?AVcr_stage_` |
| 解析出 vtable 的 stage | **353** | `vtable_scan.py`（RTTI → COL → vtable） |
| 虚函数地址 | **7,643** | 同上，逐表读到 .text 边界 |
| DXBC 着色器 | **294** | `dxbc_dump.py` |
| 常量缓冲结构 | 143 个 `Uniforms*` | 解析 RDEF 字符串 |
| 着色器绑定名 | 1,802 | 同上 |
| 立即数常量 | 见 §3 | `dxbc_consts.py`（SHEX 浮点筛） |

## 2. 关键算子的函数级定位（可直接喂给 Ghidra / IDA）

下表 RVA 是**文件内 RVA**，`绝对地址 = 0x4FAD0000 + RVA`。
在 Ghidra 里可以直接 `G` 跳转，或者用 `tools/re/ghidra_rename_stages.py` 一键给 7,643 个函数改名。

| stage | vtable RVA | 虚函数数 | 前 8 个虚函数 RVA |
|---|---|---|---|
| `cr_stage_local_contrast` | `0x33407C8` | 24 | `0x13EFFC0` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0x13EBE10` `0x1B4E8B0` |
| `cr_stage_LocalContrastY` | `0x33406C0` | 24 | `0x13EFF30` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0x13EB500` `0x1B4E8B0` |
| `cr_stage_localized_detail` | `0x33409B0` | 27 | `0x13F0150` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x13EDD70` `0x1B4E7A0` `0x13ED9D0` `0x13F0590` |
| `cr_stage_texture_direct_gf_ycc` | `0x8CD2780` | 27 | `0x1D78A00` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1D7CE70` `0x1D7CEF0` `0x1D75270` `0x13F0590` |
| `cr_stage_dehaze` | `0x33E9178` | 27 | `0x1506CE0` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0x15018B0` `0x13F0590` |
| `cr_stage_dark_channel` | `0x33E92B8` | 24 | `0x1506C50` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0x1B4E8A0` `0x1B4E8B0` |
| `cr_stage_denoise` | `0x8BC91A0` | 27 | `0x1A595A0` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1A504B0` `0x1A503C0` `0x1A50730` `0x13F0590` |
| `cr_stage_wavelet` | `0x8BC90B0` | 24 | `0x1A59850` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x19D7C70` `0x19D7CC0` `0x19D7CF0` `0x1B4E8B0` |
| `cr_stage_bilateral_blur` | `0x32E5560` | 24 | `0x1304C50` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x13044E0` `0x1B4E7A0` `0x1304570` `0x1B4E8B0` |
| `cr_stage_sharpen_3` | `0x8CC1A58` | 27 | `0x1CB8A20` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1CADB50` `0x1B4E7A0` `0x1CADB80` `0x13F0590` |
| `cr_stage_output_sharpen` | `0x8BFF388` | 24 | `0x1AAB240` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1AA4890` `0x1B4E7A0` `0x1AA4920` `0x1B4E8B0` |
| `cr_stage_HSLTuner` | `0x7F688D8` | 27 | `0x175CA50` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0x17550D0` `0x13F0590` |
| `cr_stage_LuminanceTuner` | `0x7F68CC8` | 27 | `0x175CDA0` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0x1758F40` `0x13F0590` |
| `cr_stage_SplitTone` | `0x8CC4590` | 24 | `0x1D3BBA0` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0x1D39B00` `0x1B4E8B0` |
| `cr_stage_GrayMixer` | `0x7F61858` | 24 | `0x171EA80` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0x171DE90` `0x1B4E8B0` |
| `cr_stage_post_crop_vignette` | `0x9032F98` | 24 | `0xD75090` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0xD6B900` `0x1B4E8B0` |
| `cr_stage_overlay_grain` | `0x7F61288` | 27 | `0x171C320` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1718EE0` `0x1B4E7A0` `0x1718F70` `0x13F0590` |
| `cr_stage_glow` | `0x7C3A848` | 27 | `0x160B2A0` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x1B4E780` `0x1B4E7A0` `0x1607400` `0x13F0590` |
| `cr_stage_moire` | `0x8BB6490` | 27 | `0x19A00C0` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x199C4F0` `0x1B4E7A0` `0x199C520` `0x13F0590` |
| `cr_stage_defringe_two_colors` | `0x33E7AF0` | 27 | `0x14FA9E0` `0xEE83E0` `0xFC4BD0` `0x1B4E770` `0x14FD680` `0x1B4E7A0` `0x14EF940` `0x13F0590` |

> 其中 `cr_stage_dehaze` 的虚表首项 `0x1506CE0` 就是 `process()` 候选，
> `cr_stage_LocalContrastY` 的 `0x13EFF30` 同理；vtable[0]/[1] 是析构，
> 所以真正的业务入口一般在第 7、8 项（索引 6/7）附近。

## 3. 立即数常量（按 uniform 家族归类）

筛子：float32 且 `%.6g` 能精确还原。随机浮点过筛率只有几个百分点。

| 家族 | 常量（出现次数降序） | 用途判定 |
|---|---|---|
| LocalContrast | 32, 6, 0.5, 2 | 半径按长边 /32；增益归一化 /6 |
| Sharpen | 0.03125(=1/32), 0.555556(=5/9), 1.8, 6.53606 | 高通阈值基准 / 细节斜率 |
| Denoise | 0.5, 0.25, 0.4, 0.05, 0.08, 0.64 | 边缘门限 0.4 / 细节门限 0.05 |
| Dehaze | 0.00390625(=1/256), 0.5, 2, 16 | 8bit 归一化 / 采样步长 |
| HSLTuner / LuminanceTuner | 见 `dxbc_const_family.md` | 8 带权重 |

这些值已经写进 `ACRCalibration`（`ACRDevelopEngine.swift` 顶部），
目前直接生效的是两条：`clarityRadiusDivisor = 32`、`sharpenThresholdBase = 1/32`。

## 4. 复现命令

```bash
cd tools/re
python vtable_scan.py            # 353 张 vtable + 7643 个虚函数 → stage_vtables.csv
python dxbc_consts.py            # 294 张着色器的立即数 → dxbc_consts.csv
python dxbc_dump.py              # DXBC 容器 + RDEF 绑定名 → d_shader_names.txt
```

## 5. 与实现文件的对应

| 证据 | 落到哪段 Swift |
|---|---|
| `cr_stage_LocalContrastY` + 常量 32 | `ACRDevelopEngine.stageClarity` |
| `cr_stage_texture_direct_gf_ycc` + `fEpsY/C1/C2` | `ACRDevelopEngine.stageTexture` / `guidedFilterYCC` |
| `cr_stage_dehaze` + `f_t0 / f_th2_ay_inv / f_ay_inv` | `ACRDevelopEngine.stageDehaze` |
| `cr_stage_sharpen_3` + 0.03125 / 0.555556 | `ACRDevelopEngine.stageSharpen` |
| `cr_stage_denoise` + 0.4 / 0.05 | `ACRDevelopEngine.stageNoiseReduction` |
| `UniformsRGBCurve / LumaCurve / RGBTable` | `ACRLookCube`（33³ LUT） |
| `cr_stage_HSLTuner / SplitTone / LocalColorToning` | `ACRLookCube.Color` |
