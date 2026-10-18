import Foundation
import SwiftUI
import WebKit

@MainActor
struct WebMountRunReportSheet: View {
    let sessionRecord: IOSWebMountSessionRecord?
    let onClose: () -> Void

    @State private var reports: [IOSWebMountRunReport] = []
    @State private var isLoading = true
    private let ledger = IOSAgentRunLedger()

    var body: some View {
        NavigationStack {
            Group {
                if reports.isEmpty && isLoading {
                    ProgressView("正在读取运行记录…")
                        .tint(AmberTheme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !reports.isEmpty {
                    reportContent(reports)
                } else {
                    emptyState
                }
            }
            .background(AmberTheme.surface2)
            .navigationTitle("运行报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task { await reloadReports() }
                    }
                    .disabled(isLoading || sessionRecord == nil)
                    .accessibilityIdentifier("webmount.runReport.refresh")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", systemImage: "xmark", action: onClose)
                }
            }
        }
        .task(id: sessionRecord?.id) {
            await reloadReports()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("webmount.runReport.root")
    }

    private func reloadReports() async {
        guard let sessionRecord else {
            reports = []
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        reports = await ledger.webMountRunReports(
            sessionId: sessionRecord.id,
            ownerConversationId: sessionRecord.ownerConversationId,
            ownerRunId: sessionRecord.ownerRunId
        )
    }

    func reportContent(_ reports: [IOSWebMountRunReport]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("调用总数和时长按整次 Agent 运行统计；WebMount 次数、失败/拒绝与交还次数只计入结果明确关联当前会话的步骤。时间线中的其他工具用于运行上下文。")
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                AmberSectionLabel(text: "Agent 运行")
                VStack(spacing: 12) {
                    ForEach(reports) { report in
                        runSection(report)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("webmount.runReport.content")
    }

    private func runSection(_ report: IOSWebMountRunReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    runStatus(report)
                    Spacer(minLength: 4)
                    runDate(report, allowsWrapping: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    runStatus(report)
                    runDate(report, allowsWrapping: true)
                }
            }
            .foregroundStyle(AmberTheme.muted)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                metric("\(report.totalToolCalls)", title: "运行调用")
                metric("\(report.webMountToolCalls)", title: "网页工具调用")
                metric("\(report.failedToolCalls)", title: "失败")
                metric("\(report.rejectedToolCalls)", title: "拒绝")
                metric("\(report.userHandoffCount)", title: "交还用户")
                metric(durationText(report.durationMillis), title: "墙钟时长")
            }

            Text("调用时间线")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .padding(.top, 2)
            if report.steps.isEmpty {
                Text("没有可显示的工具调用记录。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            } else {
                VStack(spacing: 8) {
                    ForEach(report.steps) { step in
                        WebMountRunReportStepRow(step: step)
                    }
                }
            }
        }
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusMedium)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
        .accessibilityIdentifier("webmount.runReport.run.\(report.id)")
    }

    private func runStatus(_ report: IOSWebMountRunReport) -> some View {
        Label(report.isRunning ? "运行中" : "已结束",
              systemImage: report.isRunning ? "circle.fill" : "circle")
            .font(.caption.weight(.medium))
            .fixedSize()
    }

    private func runDate(_ report: IOSWebMountRunReport, allowsWrapping: Bool) -> some View {
        Text(dateText(report.startedAtMillis))
            .font(.caption2)
            .foregroundStyle(AmberTheme.muted)
            .lineLimit(allowsWrapping ? nil : 1)
            .truncationMode(.middle)
            .fixedSize(horizontal: !allowsWrapping, vertical: true)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(AmberTheme.muted2)
            Text("暂无可归属的运行记录")
                .font(.body.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
            Text("报告只读取现有 Agent 工具记录，并按 WebMount 会话 ID 归属步骤。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("webmount.runReport.empty")
    }

    private func metric(_ value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
    }

    private func durationText(_ milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func dateText(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct WebMountRunReportStepRow: View {
    let step: IOSWebMountRunReportStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.toolName)
                    .font(.subheadline.weight(.semibold).monospaced())
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let timestampMillis = step.timestampMillis {
                    Text(Date(timeIntervalSince1970: Double(timestampMillis) / 1_000).formatted(date: .omitted, time: .shortened))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize()
                }
            }

            Text(step.targetSummary)
                .font(.caption)
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { receiptBadges }
                VStack(alignment: .leading, spacing: 6) { receiptBadges }
            }

            if let errorCode = step.errorCode {
                Text("错误码：\(errorCode)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(AmberTheme.accentRed)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if step.handedOffToUser { flag("已交还用户", systemImage: "person.crop.circle") }
            if step.pageDrift { flag("页面漂移", systemImage: "arrow.triangle.2.circlepath") }
            if step.credentialRedacted { flag("凭据已隐去", systemImage: "lock.fill") }
            if step.unattributedPageActivity { flag("存在未归因页面活动", systemImage: "waveform.path") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusMedium)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("webmount.runReport.step.\(step.id)")
    }

    @ViewBuilder
    private var receiptBadges: some View {
        receipt("派发", value: step.dispatched)
        receipt("页面变化", value: step.pageChanged)
        receipt("目标验证", value: step.goalVerified)
    }

    private func receipt(_ title: String, value: Bool?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(value == true ? AmberTheme.accent : AmberTheme.muted2)
                .frame(width: 5, height: 5)
            Text("\(title)·\(value.map { $0 ? "是" : "否" } ?? "未知")")
                .font(.caption2)
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(AmberTheme.surface2, in: Capsule())
    }

    private func flag(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(AmberTheme.foreground2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
