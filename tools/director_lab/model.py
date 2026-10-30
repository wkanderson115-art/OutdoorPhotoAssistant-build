"""DirectorNet：MobileNetV3-Small 主干 + 三个输出头。

输入   image  (B,3,224,224) RGB，取值 0..1（Core ML 的 ImageType 会把 0..255 缩放到 0..1）
       aspect (B,1)         取景画面 宽/高（竖屏 0.75，横屏 1.33），让同一个模型同时适配横竖屏
输出   scene   (B,N) softmax 概率，顺序见 geometry.SCENES
       quality (B,1) 0..1，当前取景离理想取景有多近
       shift   (B,3) dx, dy, dz，含义见 geometry.py
"""
import torch
import torch.nn as nn
import torchvision

from .geometry import SCENES

MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)


class DirectorNet(nn.Module):
    def __init__(self, n_scenes: int = len(SCENES), pretrained: bool = True):
        super().__init__()
        weights = torchvision.models.MobileNet_V3_Small_Weights.DEFAULT if pretrained else None
        backbone = torchvision.models.mobilenet_v3_small(weights=weights)
        self.features = backbone.features            # 输出 576 通道
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.trunk = nn.Sequential(nn.Linear(576 + 2, 256), nn.Hardswish(), nn.Dropout(0.1))
        self.scene = nn.Linear(256, n_scenes)
        self.quality = nn.Linear(256, 1)
        self.shift = nn.Linear(256, 3)
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward_logits(self, image, aspect):
        x = (image - self.mean) / self.std
        f = self.pool(self.features(x)).flatten(1)
        a = torch.cat([aspect, torch.log(aspect.clamp(min=0.2))], dim=1)
        h = self.trunk(torch.cat([f, a], dim=1))
        return self.scene(h), self.quality(h), self.shift(h)

    def forward(self, image, aspect):
        s, q, d = self.forward_logits(image, aspect)
        return torch.softmax(s, dim=1), torch.sigmoid(q), torch.tanh(d)
