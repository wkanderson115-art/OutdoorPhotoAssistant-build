import Foundation

var failures = 0

func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: " + label)
    }
}

let passing = RetouchQualityReport(
    passed: true,
    metrics: ["clipping_full": 0.001, "ssim": 0.97],
    notes: []
)

let architecture = AIEditAdvisor.makeAdvice(
    report: passing, look: .landscapeNatural, presetID: "p53",
    strength: 1.0, spotsFound: 0, spotsRemaining: 0,
    shootingMode: .product
)
expect(architecture.sceneCategory == "建筑与室内", "建筑预设保留建筑分类")
expect(architecture.subjectMode == "商品／建筑", "建筑使用商品建筑模式")
expect(architecture.prompt.contains("垂直线"), "建筑提示包含垂直线和透视规则")
expect(architecture.prompt.contains("不执行磨皮"), "无人建筑明确禁用人像处理")
expect(!architecture.items.contains { $0.metric.contains("肤") }, "建筑建议不生成肤色项目")

let portrait = AIEditAdvisor.makeAdvice(
    report: passing, look: .commercialNatural, presetID: "p01",
    strength: 1.0, spotsFound: 2, spotsRemaining: 0,
    shootingMode: .portrait
)
expect(portrait.subjectMode == "人物", "检出人物时使用人物模式")
expect(portrait.prompt.contains("人物保护优先"), "人物提示保护身份与五官")
expect(portrait.items.contains { $0.metric == "肤质保护" }, "人物建议包含肤质保护")

let landscape = AIEditAdvisor.makeAdvice(
    report: passing, look: .landscapeNatural, presetID: "p25",
    strength: 1.0, spotsFound: 0, spotsRemaining: 0,
    shootingMode: .scene
)
expect(landscape.subjectMode == "自然场景", "无人风景使用自然场景模式")
expect(landscape.prompt.contains("不换天空"), "风景提示禁止换天")
expect(landscape.items.contains { $0.metric == "天空真实性" }, "风景建议随题材变化")

if failures > 0 {
    fatalError("advisor tests failed: \(failures)")
}
print("AI advisor scene tests passed")
