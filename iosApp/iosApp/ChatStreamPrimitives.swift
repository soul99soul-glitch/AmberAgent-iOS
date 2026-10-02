import CryptoKit
import Foundation
@preconcurrency import Shared
import UIKit

// Stream primitives shared by the foreground Host, background coordinator,
// Council, and Novel flows.

func chatInputDigest(for text: String) -> String {
    let hash = SHA256.hash(data: Data(text.utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
}

func chatNowLocalDateTime() -> Kotlinx_datetimeLocalDateTime {
    let now = Date()
    let cal = Calendar.current
    return Kotlinx_datetimeLocalDateTime(
        year: Int32(cal.component(.year, from: now)),
        month: Int32(cal.component(.month, from: now)),
        day: Int32(cal.component(.day, from: now)),
        hour: Int32(cal.component(.hour, from: now)),
        minute: Int32(cal.component(.minute, from: now)),
        second: Int32(cal.component(.second, from: now)),
        nanosecond: Int32(cal.component(.nanosecond, from: now))
    )
}

final class ChatStreamEvent: @unchecked Sendable {
    enum Payload {
        case chunk(MessageChunk)
        case complete
        case error(KotlinThrowable)
    }

    let payload: Payload

    private init(_ payload: Payload) {
        self.payload = payload
    }

    static func chunk(_ chunk: MessageChunk) -> ChatStreamEvent {
        ChatStreamEvent(.chunk(chunk))
    }

    static func complete() -> ChatStreamEvent {
        ChatStreamEvent(.complete)
    }

    static func error(_ error: KotlinThrowable) -> ChatStreamEvent {
        ChatStreamEvent(.error(error))
    }
}

final class ChatStreamEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ChatStreamEvent>.Continuation?
    private var pendingEvents: [ChatStreamEvent] = []
    private var pendingEventHead = 0
    private var isFinished = false

    func bind(_ continuation: AsyncStream<ChatStreamEvent>.Continuation) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.finish()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ event: ChatStreamEvent) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        pendingEvents.append(event)
        // `yield` 也放在锁内，确保不同 provider 回调线程看到同一 FIFO 次序。
        continuation.yield(event)
        lock.unlock()
    }

    func claim(_ event: ChatStreamEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingEventHead < pendingEvents.count,
              pendingEvents[pendingEventHead] === event else {
            return false
        }
        pendingEventHead += 1
        compactClaimedPrefixIfNeeded()
        return true
    }

    func takePendingChunks() -> [MessageChunk] {
        lock.lock()
        defer { lock.unlock() }
        var chunks: [MessageChunk] = []
        var retained: [ChatStreamEvent] = []
        if pendingEventHead < pendingEvents.count {
            retained.reserveCapacity(pendingEvents.count - pendingEventHead)
            for event in pendingEvents[pendingEventHead...] {
                if case .chunk(let chunk) = event.payload {
                    chunks.append(chunk)
                } else {
                    retained.append(event)
                }
            }
        }
        pendingEvents = retained
        pendingEventHead = 0
        return chunks
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        isFinished = true
        lock.unlock()
        continuation?.finish()
    }

    /// Atomically chooses background ownership against a racing provider terminal callback.
    /// Accepted chunks remain drainable; a queued complete/error keeps foreground ownership.
    @MainActor
    func transitionToBackgroundIfNoTerminal(_ startBackground: () -> Bool) -> Bool {
        lock.lock()
        guard !isFinished,
              !pendingEvents[pendingEventHead...].contains(where: { event in
                switch event.payload {
                case .complete, .error:
                    return true
                case .chunk:
                    return false
                }
              }) else {
            lock.unlock()
            return false
        }
        let didStart = startBackground()
        let continuation = didStart ? continuation : nil
        if didStart {
            self.continuation = nil
            isFinished = true
        }
        lock.unlock()
        continuation?.finish()
        return didStart
    }

    private func compactClaimedPrefixIfNeeded() {
        guard pendingEventHead >= 64,
              pendingEventHead * 2 >= pendingEvents.count else { return }
        pendingEvents.removeFirst(pendingEventHead)
        pendingEventHead = 0
    }

#if DEBUG
    var pendingEventCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingEvents.count - pendingEventHead
    }
#endif
}

/// 流式「呈现节奏」策略：需要渐进发布文本的消费者共用同一份字符推进口径。
/// 这里只保留与具体消息形状无关的步长和终态排空公式。
enum StreamPresentationPacingPolicy {
    /// 轻积压时的下限:一拍推进不到一行手机宽度的中文,保留既有 48ms 发布时钟。
    static let minimumTextAdvance = 12
    /// 每拍硬上限:约一到两行中文。64 字会在手机宽度下一次放出约三行，
    /// TextKit 高度与底部跟随只能在下一帧追上，表现为偶发的大幅跳变。
    static let maximumTextAdvance = 36
    /// 尽量在这么多拍内清空*当前*积压。
    static let preferredDrainTicks = 16
    /// 24K-char terminal bursts are the observed worst normal reply; drain
    /// that backlog within the existing 16 ticks without changing live pacing.
    /// Shared by the novel and council presentation sessions.
    static let terminalMaximumTextAdvance = 24 * 1_024 / preferredDrainTicks

    /// 按积压自适应的每拍推进量。
    ///
    /// 固定 12 字符/拍意味着显示速率恒为 250 字符/秒。模型快于这个速率时
    /// 积压会持续累积,且终态排空仍按同一节奏逐拍追平——4000 字的回复要 334 拍
    /// (≈16s)才显示完,期间 `isLoading` 保持 true,用户看着"停止"按钮等一段
    /// 早已生成完的文本。
    static func textAdvance(backlogCount: Int) -> Int {
        guard backlogCount > 0 else { return 0 }
        let adaptive = (backlogCount + preferredDrainTicks - 1) / preferredDrainTicks
        return min(maximumTextAdvance, max(minimumTextAdvance, adaptive))
    }

    /// 终态排空的节奏锚：整轮由完成时积压一次决定，不逐拍衰减。
    /// 连续于积压、无阈值断点——小积压（几十字）≈12 字/拍 × 48ms；大积压
    /// 趋近 1500 字/拍 × 8ms，约 16 拍 whoosh。小说与 Council 共用。
    static func terminalDrainAdvance(backlogCount: Int) -> Int {
        guard backlogCount > 0 else { return 0 }
        let adaptive = (backlogCount + preferredDrainTicks - 1) / preferredDrainTicks
        return min(terminalMaximumTextAdvance, max(minimumTextAdvance, adaptive))
    }

    /// 排空拍间隔：由整轮节奏锚决定。advance≤36 保持 48ms 流式节拍；
    /// advance 1500 时 8ms（120Hz 逐帧）。
    static func terminalDrainDelayNanos(advance: Int) -> UInt64 {
        let intervalMs = min(48.0, max(8.0, 48.0 * Double(maximumTextAdvance) / Double(max(advance, 1))))
        return UInt64(intervalMs * 1_000_000)
    }

    /// 收尾减速的除数：末段拍速 = max(12, 剩余/8)，与锚速取小。
    /// 大积压中段保持 whoosh，最后 ~锚速×8 字连续减速，末拍回到打字节奏
    /// （12 字/拍 × 48ms），配合按拍缩放的淡入自动恢复完整 0.5s——
    /// 「最后一个字优雅地逐字淡入结束」的产品契约。
    static let gracefulTailDivisor = 8

    /// 终态单拍推进量；`fixedAdvance` 为完成时定锚的整轮节奏上限，
    /// 实际每拍随剩余积压连续收敛（graceful tail），不再整轮恒速。
    static func terminalTextAdvance(
        backlogCount: Int,
        fixedAdvance: Int? = nil
    ) -> Int {
        guard backlogCount > 0 else { return 0 }
        let anchor = fixedAdvance ?? (backlogCount + preferredDrainTicks - 1) / preferredDrainTicks
        let anchorClamped = min(terminalMaximumTextAdvance, max(minimumTextAdvance, anchor))
        let gracefulTail = max(minimumTextAdvance, (backlogCount + gracefulTailDivisor - 1) / gracefulTailDivisor)
        return min(anchorClamped, gracefulTail)
    }

    /// 滚动跟随的滞后允许度（1=流式期，→0=排空收尾）。排空期间它随剩余积压
    /// 连续衰减，跟随器的时间常数随之收紧（τ_eff = τ × allowance），视口在
    /// 最后一拍落定前贴回底部——完成瞬间的钉底不再需要一次性清掉跟随滞后。
    static func lagAllowance(remainingBacklog: Int, drainStartBacklog: Int) -> CGFloat {
        guard drainStartBacklog > 0, remainingBacklog > 0 else { return 0 }
        return CGFloat(min(1, Double(remainingBacklog) / Double(drainStartBacklog)))
    }
}

extension TextGenerationParams {
    /// P0-a: a copy of these params carrying a different tool declaration list.
    /// Kotlin data-class default args don't bridge to Swift, so rebuild all
    /// fields explicitly (same shape makeTextGenerationParams uses).
    func replacingTools(_ tools: [Tool]) -> TextGenerationParams {
        TextGenerationParams(
            model: model,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            tools: tools,
            reasoningLevel: reasoningLevel,
            customHeaders: customHeaders,
            customBody: customBody
        )
    }
}
