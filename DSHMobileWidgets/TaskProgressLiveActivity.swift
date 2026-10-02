import ActivityKit
import SwiftUI
import WidgetKit

// DSHMobile 的实时活动 Widget（灵动岛 + 锁屏 + 横幅 + 通知中心）。
//
// 由主 App 用 ActivityKit 启动/更新/结束实时活动，本扩展负责渲染：
//   - dynamicIsland 闭包：灵动岛（compact 折叠态 / expanded 展开态 / minimal 极简态）
//   - content 闭包：锁屏与通知横幅（同时也是 iPhone 无灵动岛机型上的横幅样式）
//
// 免费签名（SideStore）无法使用 APNs 远程推送，因此实时活动的更新全部由
// App 本地发起（Activity.request / update / end），无需 pushType。

@main
struct TaskProgressWidgets: WidgetBundle {

    var body: some Widget {
        TaskProgressLiveActivity()
    }
}

struct TaskProgressLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskProgressAttributes.self) { context in
            // ── 锁屏 / 横幅 ──────────────────────────────────────────
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            // ── 灵动岛 ──────────────────────────────────────────────
            DynamicIsland {
                // 展开态
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(context: context)
                }
            } compactLeading: {
                compactLeading
            } compactTrailing: {
                Text(percentText(context.state.progress))
                    .font(.system(.body, design: .rounded).bold())
                    .monospacedDigit()
            } minimal: {
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
            }
        }
    }

    // MARK: - 灵动岛展开态组件

    private var expandedLeading: some View {
        Label("DSH 任务", systemImage: "sparkles")
            .font(.headline)
    }

    private func expandedBottom(context: ActivityViewContext<TaskProgressAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: context.state.progress)
                .progressViewStyle(.linear)
                .tint(.purple)
            HStack(alignment: .firstTextBaseline) {
                Text(context.state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if context.state.chars > 0 {
                    Text("\(context.state.chars) 字符")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - 折叠态组件

    private var compactLeading: some View {
        Label("DSH", systemImage: "sparkles")
            .font(.headline)
    }

    private func percentText(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1)) * 100))%"
    }
}

// MARK: - 锁屏 / 横幅视图

struct LockScreenView: View {
    let context: ActivityViewContext<TaskProgressAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("DSH 任务", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text(context.state.status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(context.state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            ProgressView(value: context.state.progress)
                .progressViewStyle(.linear)
                .tint(.purple)

            HStack {
                Text(context.attributes.sessionTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if context.state.chars > 0 {
                    Text("\(context.state.chars) 字符")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
    }
}
