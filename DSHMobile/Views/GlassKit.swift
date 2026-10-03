import SwiftUI

// MARK: - 液态玻璃（Liquid Glass）基础件
//
// 为什么不是直接 .glassEffect()：那是 iOS 26 的 API，而本 App 支持 iOS 17，
// 且 CI 的 Xcode 版本不保证有 iOS 26 SDK。这里用 iOS 17 就能实现"看起来像液态玻璃"
// 的三要素：
//   1. 背后有内容 —— AuroraBackground 的彩色光斑（玻璃没有可折射的东西就只是一块灰板）
//   2. 半透明模糊 —— .ultraThinMaterial 采样背后的光斑，得到真实的折射感
//   3. 厚度 —— 顶部高光 + 渐变描边 + 外阴影，勾出玻璃的边缘与体积
// 顶栏与原生输入条都以"悬浮玻璃岛"形式浮在光斑之上（四周留边，能看到底下的光）。

enum DSGlass {
    /// 大面板圆角（顶栏 / 输入条）
    static let panelCorner: CGFloat = 26
    /// 小控件圆角
    static let chipCorner: CGFloat = 16
    /// 玻璃高光描边（上亮下暗，模拟反射）
    static let strokeTop = Color.white.opacity(0.34)
    static let strokeBottom = Color.white.opacity(0.06)
    /// 玻璃投影
    static let shadow = Color.black.opacity(0.38)
}

/// 深色底 + 缓慢漂移的彩色光斑：玻璃"看得见的折射内容"来自这里。
struct AuroraBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.08)
            Circle()
                .fill(Color.purple.opacity(0.60))
                .frame(width: 320, height: 320)
                .blur(radius: 85)
                .offset(x: drift ? -120 : -70, y: drift ? -140 : -100)
            Circle()
                .fill(Color.blue.opacity(0.48))
                .frame(width: 300, height: 300)
                .blur(radius: 90)
                .offset(x: drift ? 120 : 70, y: drift ? 150 : 210)
            Circle()
                .fill(Color.pink.opacity(0.34))
                .frame(width: 240, height: 240)
                .blur(radius: 85)
                .offset(x: drift ? -70 : 50, y: drift ? 250 : 300)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 14).repeatForever(autoreverses: true), value: drift)
        .onAppear { drift = true }
    }
}

/// 玻璃面板外观：半透明材质 + 顶部高光 + 渐变描边 + 外阴影
private struct GlassSurface: ViewModifier {
    let corner: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(.ultraThinMaterial)
                    if let tint {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(tint.opacity(0.14))
                    }
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), Color.white.opacity(0)],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [DSGlass.strokeTop, DSGlass.strokeBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: DSGlass.shadow, radius: 16, x: 0, y: 8)
    }
}

extension View {
    /// 液态玻璃面板（顶栏、输入条、浮层卡片）
    func dsGlassPanel(corner: CGFloat = DSGlass.panelCorner, tint: Color? = nil) -> some View {
        modifier(GlassSurface(corner: corner, tint: tint))
    }

    /// 玻璃圆形图标按钮的外观（直接作用在 Button 的 label 上）
    /// - Parameters:
    ///   - active: 选中/高亮态（用紫色实心填充）
    ///   - size: 圆形直径
    func dsGlassIcon(active: Bool = false, size: CGFloat = 32) -> some View {
        self
            .font(.system(size: 15, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(active ? Color.white : Color.purple)
            .background {
                if active {
                    Circle().fill(Color.purple)
                } else {
                    Circle().fill(.ultraThinMaterial)
                }
            }
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [DSGlass.strokeTop, DSGlass.strokeBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.7
                )
            }
            .shadow(color: DSGlass.shadow, radius: 5, x: 0, y: 3)
    }

    /// 玻璃小胶囊（排队/插话、附件胶囊等）
    func dsGlassCapsule(tint: Color = .purple, active: Bool = false) -> some View {
        self
            .foregroundStyle(active ? Color.white : Color.purple)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                active ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [DSGlass.strokeTop, DSGlass.strokeBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.7
                )
            }
    }
}
