import SwiftUI
import UIKit

struct RootView: View {
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            CaptureView(isSelected: selectedTab == 0, onNavigate: { selectedTab = $0 })
                .tabItem { Label("拍摄", systemImage: "camera.fill") }
                .tag(0)
            GalleryView()
                .tabItem { Label("图库", systemImage: "photo.on.rectangle") }
                .tag(1)
            RetouchStudioView()
                .tabItem { Label("精修台", systemImage: "wand.and.stars") }
                .tag(4)
            LearningView()
                .tabItem { Label("学院", systemImage: "book") }
                .tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }.toolbar(selectedTab == 0 ? .hidden : .visible, for: .tabBar)
            .tint(selectedTab == 0 ? AppTheme.mint : AppTheme.ink)
            .preferredColorScheme(selectedTab == 0 ? .dark : .light)
    }
}

struct PhotoLesson: Identifiable {
    let id: Int
    let category: String
    let title: String
    let principle: String
    let exercise: String
    let mistake: String
    let acceptance: String
    static let all: [PhotoLesson] = [
        PhotoLesson(id: 0, category: "构图", title: "三分与留白", principle: "把主体放在三分线附近，是起点而非硬性规则；先判断视线和运动方向。", exercise: "打开网格拍三张：居中、左三分、右三分；给视线方向多留一点空间。", mistake: "只顾交点而切掉头顶、手脚；没有主体仍机械套网格。", acceptance: "能指出画面的第一视觉落点；人物视线方向有呼吸空间。"),
        PhotoLesson(id: 1, category: "构图", title: "地平线与建筑垂直", principle: "地平线轻微歪斜会让平静场景不安定；建筑透视来自拍摄角度。", exercise: "拍摄前对齐海面或门框；拍建筑先后退并保持手机竖直，再决定是否校正。", mistake: "把正常透视全部拉直，导致建筑被拉宽。", acceptance: "海面看起来水平，建筑不被明显拉伸，边角没有重要信息被裁掉。"),
        PhotoLesson(id: 2, category: "构图", title: "检查画面四边", principle: "边缘亮点、杂物和被截断的肢体常比主体更抢眼。", exercise: "拍前沿四边扫一圈；移动半步避开路牌、垃圾桶和穿过头部的树枝。", mistake: "只用后期裁切解决所有问题，损失像素和环境。", acceptance: "主体轮廓干净，四角没有明显抢眼的无关物。"),
        PhotoLesson(id: 3, category: "构图", title: "前景与空间层次", principle: "前景、中景和远景能提供距离线索；前景必须服务主体。", exercise: "用栏杆、树叶或石块建立前景；先拍一张没有前景的，再对比。", mistake: "前景过大、过亮，挡住主体或占据半个画面。", acceptance: "能清楚区分近、中、远，主体仍然最明确。"),
        PhotoLesson(id: 4, category: "构图", title: "引导线与重复", principle: "道路、岸线和建筑节奏可以引导视线，但线条终点应有意义。", exercise: "调整位置，让道路指向主体；寻找一处打破重复的小变化。", mistake: "线条把视线带出画面，主体反而藏在角落。", acceptance: "观看顺序自然，线条没有与主体争夺注意力。"),
        PhotoLesson(id: 5, category: "构图", title: "人景比例", principle: "人物占比取决于故事：环境人像需要留景，肖像更关注表情。", exercise: "同一位置拍人物高度约占画面三分之一、一半、三分之二的三张照片。", mistake: "认为人物越大越好；用超广角近距离拍脸。", acceptance: "能说明照片更侧重人物还是环境；人物与背景尺度自然。"),
        PhotoLesson(id: 6, category: "光线", title: "顺光与侧光", principle: "顺光色彩容易清楚，侧光更容易呈现形体；光越硬，阴影边缘越清晰。", exercise: "绕主体走半圈，观察鼻影和衣服纹理；选择阴影不遮眼的位置。", mistake: "只看亮度，不看光的方向；强侧光让半张脸失去细节。", acceptance: "脸部细节可辨，阴影帮助塑形而不遮住表情。"),
        PhotoLesson(id: 7, category: "光线", title: "逆光与天空高光", principle: "天空与人物亮度差太大时，手机也可能无法同时完整记录。", exercise: "先对焦人物，再小幅降低曝光保护天空；找浅色墙面反光或换角度。", mistake: "把阴影强行提到白天亮度，产生噪点和HDR光晕。", acceptance: "天空重要纹理保留，人物不灰白，亮暗过渡自然。"),
        PhotoLesson(id: 8, category: "光线", title: "阴天与树荫人像", principle: "大面积柔光适合保留皮肤质感；混合树叶光斑会让脸部明暗破碎。", exercise: "让人物站在完整树荫边缘，朝向开阔天空；避开脸上的零碎光斑。", mistake: "站在浓绿树叶下面却忽略皮肤偏绿。", acceptance: "眼窝不过黑，脸部受光均匀，肤色没有明显绿偏。"),
        PhotoLesson(id: 9, category: "光线", title: "黄金与蓝调时段", principle: "低角度暖光和日落后冷色天空提供不同氛围，不必把所有画面变橙。", exercise: "日落前后在同一位置各拍一次，保持自然白平衡作对照。", mistake: "暖色滤镜叠加过强，使白衣变黄、肤色变橙。", acceptance: "能保留现场冷暖关系，白色物体仍可信。"),
        PhotoLesson(id: 10, category: "清晰度", title: "对焦与拍摄距离", principle: "对焦决定清晰平面；距离太近可能低于镜头最近对焦距离。", exercise: "点按主体边缘后等画面稳定；拍小物先后退一点再拍。", mistake: "模糊时不停加锐化，或直接把手机贴到物体表面。", acceptance: "主体关键部位清晰；无明显对焦来回抽动。"),
        PhotoLesson(id: 11, category: "清晰度", title: "快门、ISO与固定光圈", principle: "快门影响运动模糊，ISO提高会放大噪点；固定光圈镜头不能靠软件收缩。", exercise: "对同一物体在亮处和暗处各拍一张，比较ISO、快门与细节；暗处先稳住手机。", mistake: "把软件虚化强度当作真实光圈；认为高ISO能无代价增亮。", acceptance: "能区分噪点、手抖和失焦；知道应先补光、稳定还是重对焦。"),
        PhotoLesson(id: 12, category: "清晰度", title: "暗光手持", principle: "暗光时曝光时间可能变长，呼吸与按快门动作都会影响细节。", exercise: "双手握持、肘部靠身，轻按快门后继续停留半秒；比较三张照片。", mistake: "快门刚按下就移动手机，或在暗处自动放大。", acceptance: "三张中至少两张静态主体边缘清楚；数字变焦保持克制。"),
        PhotoLesson(id: 13, category: "清晰度", title: "移动人物与宠物", principle: "移动主体需要更短曝光；亮处比强行提ISO更容易获得干净细节。", exercise: "找更亮的位置，预判主体将进入的位置，先完成对焦再拍。", mistake: "暗处拍奔跑主体，却把所有拖影归因于对焦。", acceptance: "眼睛或头部可辨，背景与主体没有同方向的全局拖影。"),
        PhotoLesson(id: 14, category: "镜头", title: "超广角的边缘变形", principle: "超广角扩大视野，也会夸大靠近镜头的物体及画面边缘比例。", exercise: "人物保持靠中间，手机不贴脸；建筑拍一张0.5倍和一张后退的1倍对比。", mistake: "把人放在最边缘，导致脸和四肢拉长。", acceptance: "人物比例自然；超广角带来的空间感符合意图。"),
        PhotoLesson(id: 15, category: "镜头", title: "自动变焦与手动接管", principle: "自动变焦依据主体占比，只能辅助构图，无法判断你要讲的全部故事。", exercise: "在明亮场景让主体缓慢远近移动；再手动选1倍，观察是否留出接管时间。", mistake: "远处主体无限数字放大；主体靠边时仍继续推近。", acceptance: "取景不反复拉风箱，人物完整；需要留景时能手动保持倍率。"),
        PhotoLesson(id: 16, category: "色彩", title: "滤镜强度与自然色", principle: "滤镜是风格选择，不能修复失焦或找回完全过曝的细节。", exercise: "同一原片对比0%、约一半和100%强度；优先检查皮肤、天空与白色物体。", mistake: "连续叠加暖色、高饱和与强对比。", acceptance: "成片保留现场色彩关系，没有不必要的色块与橙脸。"),
        PhotoLesson(id: 17, category: "色彩", title: "白平衡与混合光", principle: "窗外日光和室内灯光同时照射时，画面不同位置可能有不同色偏。", exercise: "关掉一种灯或让人物只受窗光；用白衣或灰色物体作参照。", mistake: "用整体色温修正局部光源，导致另一半画面更偏色。", acceptance: "主要人物肤色协调，重要中性色没有明显偏色。"),
        PhotoLesson(id: 18, category: "色彩", title: "高光、阴影与HDR", principle: "自然层次需要保留明暗差；提亮所有阴影会削弱空间感。", exercise: "对比原片与成片的树枝、天际线；减少高反差边缘的白色光圈。", mistake: "阴影拉满、清晰度拉满，画面发灰发硬。", acceptance: "天空边缘没有明显光晕，阴影仍有深浅。"),
        PhotoLesson(id: 19, category: "人像", title: "自然皮肤与面部微调", principle: "真实肤质有细小纹理；面部几何调整会影响五官与背景直线。", exercise: "从零瘦脸和零面部鼓起开始，只少量增加美肤；放大检查眼睛和发际线。", mistake: "把皮肤纹理全部抹掉，脸旁栏杆被扭弯。", acceptance: "皮肤有纹理，五官可信，背景直线连续。"),
        PhotoLesson(id: 20, category: "人像", title: "虚化边缘与真实场景", principle: "人像遮罩提供前后景分离，并不等于完整的真实距离信息。", exercise: "先用零虚化，再缓慢增加；检查头发、眼镜、手指间隙和椅背。", mistake: "把整片背景模糊到没有现场信息，头发出现明显剪纸边。", acceptance: "人物大小不变、轮廓自然；环境人像仍能看清场景。"),
        PhotoLesson(id: 21, category: "场景", title: "山水与旅行", principle: "旅行照片应保留地点特征；层次和拍摄位置往往比滤镜更重要。", exercise: "先找明确主体，再检查地平线和天空占比；用横竖两张表达不同空间。", mistake: "所有风景都用超广角，远山小得没有重点。", acceptance: "地点可辨，主体明确，没有无意义的大块空白。"),
        PhotoLesson(id: 22, category: "场景", title: "夜景与城市灯光", principle: "灯牌可能比街道亮很多；保护灯牌时，环境稍暗也可以自然。", exercise: "对焦主要建筑，小幅压曝光；找栏杆支撑，避免大倍率数码变焦。", mistake: "把夜景提成白天；过度降噪把砖石抹成水彩。", acceptance: "主要文字和轮廓可辨，夜景仍有夜晚的亮暗关系。"),
        PhotoLesson(id: 23, category: "场景", title: "汽车与反光表面", principle: "车身靠反射呈现曲面；杂乱反射往往比车漆本身更影响质感。", exercise: "擦净镜头，移动位置让车身反射简洁；拍摄车身45度及低机位两张。", mistake: "站太近用超广角让车头变形；强HDR让车漆发灰。", acceptance: "车身比例可信，漆面反射连续，亮部保留曲面。")
    ]
}

struct LearningView: View {
    @State private var directorFeedbackCount = 0
    @State private var query = ""
    @State private var category = "全部"
    @AppStorage("completedLessons") private var completed = "|"
    @AppStorage("lastShotExposure") private var exposure = -1
    @AppStorage("lastShotSharpness") private var sharpness = -1
    @AppStorage("lastShotComposition") private var composition = -1
    @AppStorage("lastShotDate") private var lastShotDate = ""
    private let categories = ["全部", "构图", "光线", "清晰度", "镜头", "色彩", "人像", "场景"]
    private var filtered: [PhotoLesson] {
        PhotoLesson.all.filter {
            (category == "全部" || $0.category == category) &&
            (query.isEmpty || ($0.title + $0.principle + $0.exercise).localizedCaseInsensitiveContains(query))
        }
    }
    private var completedCount: Int { PhotoLesson.all.filter { completed.contains("|\($0.id)|") }.count }
    private var suggestedCategory: String {
        if min(exposure, min(sharpness, composition)) >= 85 { return "场景" }
        if exposure <= sharpness && exposure <= composition { return "光线" }
        if sharpness <= composition { return "清晰度" }
        return "构图"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("把每一次拍摄，变成进步").font(.title2.bold())
                        Text("24节实拍课程 · 已完成 \(completedCount) 节")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ProgressView(value: Double(completedCount), total: 24).tint(.mint)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Label("拍摄教练", systemImage: "sparkles").font(.headline)
                        Text("导演已记录 \(directorFeedbackCount) 次偏好反馈")
                            .font(.caption).foregroundStyle(.secondary)
                        if exposure >= 0 {
                            Text("上次拍摄 · " + lastShotDate).font(.caption).foregroundStyle(.secondary)
                            Text(suggestedCategory == "场景" ? "基础指标良好，试试场景练习" : "建议先练习「" + suggestedCategory + "」")
                            Text("曝光 \(exposure) · 清晰 \(sharpness) · 构图 \(composition)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("查看推荐课程") { category = suggestedCategory; query = "" }
                                .buttonStyle(.bordered)
                        } else {
                            Text("先拍一张照片，教练会根据拍摄时的曝光、稳定细节和构图估计推荐练习。")
                                .font(.subheadline)
                        }
                        Text("摄影规则与反馈偏好；未重新训练视觉模型。评分取自拍摄前预览，仅作参考。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 20))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(categories, id: \.self) { item in
                                Button { category = item } label: {
                                    Text(item).font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 15).padding(.vertical, 10)
                                        .background(category == item ? AppTheme.mint : AppTheme.card, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(filtered) { lesson in
                            NavigationLink {
                                LessonDetailView(lesson: lesson)
                            } label: {
                                HStack(spacing: 14) {
                                    Text(String(format: "%02d", lesson.id + 1))
                                        .font(.system(.title3, design: .rounded).weight(.medium))
                                        .foregroundStyle(.secondary).frame(width: 36)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(lesson.title).font(.headline).foregroundStyle(.primary)
                                        Text(lesson.category + " · 原理 / 练习 / 验收").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: completed.contains("|\(lesson.id)|") ? "checkmark.circle.fill" : "chevron.right")
                                        .foregroundStyle(.mint)
                                }.padding(18).background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain)
                        }
                        if filtered.isEmpty { Text("没有匹配课程，试试其他关键词。 ").foregroundStyle(.secondary).padding() }
                    }
                }.padding(16)
            }.background(AppTheme.paper).navigationTitle("摄影学院")
                .searchable(text: $query, prompt: "搜索逆光、虚化、夜景…")
                .onAppear { directorFeedbackCount = DirectorPreferenceStore.shared.feedbackCount }
        }
    }
}

struct LessonDetailView: View {
    let lesson: PhotoLesson
    @AppStorage("completedLessons") private var completed = "|"
    private var isComplete: Bool { completed.contains("|\(lesson.id)|") }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(lesson.category.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.mint)
                Text(lesson.title).font(.largeTitle.bold())
                section("理解原理", lesson.principle, "lightbulb")
                section("现在去拍", lesson.exercise, "camera")
                section("常见误区", lesson.mistake, "exclamationmark.bubble")
                section("自己验收", lesson.acceptance, "checkmark.seal")
                Button(isComplete ? "撤销完成" : "我已完成这次练习") {
                    let token = "|\(lesson.id)|"
                    if isComplete { completed = completed.replacingOccurrences(of: token, with: "|") }
                    else { completed += "\(lesson.id)|" }
                }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                Text("进度保存在本机，完成标记表示你已练习，不代表AI已掌握或验证拍摄效果。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.background(AppTheme.paper).navigationBarTitleDisplayMode(.inline)
    }
    private func section(_ title: String, _ text: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).font(.body).lineSpacing(6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
