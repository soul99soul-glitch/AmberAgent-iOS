import Foundation

enum NovelSessionBottomFollowMode: Equatable, Sendable {
    case awaitingInitialRows
    case followingBottom
    case browsingHistory
    case settlingTerminal(token: UInt64)
}

struct NovelSessionBottomFollowState: Equatable, Sendable {
    var mode: NovelSessionBottomFollowMode = .awaitingInitialRows
    var showsBottomButton = false
    var nextSettleToken: UInt64 = 0
}

enum NovelSessionBottomFollowEvent: Equatable, Sendable {
    case reset
    case initialRowsPresented(hasRows: Bool)
    case streamStarted
    case streamDelta
    case measuredStreamGrowth(isAtBottom: Bool)
    case measuredTerminalGrowth(isAtBottom: Bool)
    case staticContentGrowth(isAtBottom: Bool)
    case userDragBegan(isAtBottom: Bool)
    case userDragEnded(isAtBottom: Bool)
    case viewportChanged(isAtBottom: Bool)
    case explicitBottomRequested
    case terminalReached
    case terminalLayoutChanged
    case terminalQuietElapsed(token: UInt64)
}

enum NovelSessionBottomFollowCommand: Equatable, Sendable {
    case anchorBottom
    case followBottom(animated: Bool)
    /// 生成终态：driver 激活时发 generationTerminated（逐帧钉底 + 静默交还），
    /// 与 Chat 同构；driver 未激活时退回 followBottom + quietSettle。
    case terminateGeneration
    case setBottomButton(Bool)
    case scheduleTerminalQuietSettle(token: UInt64, delay: TimeInterval)
}

struct NovelSessionBottomFollowTransition: Equatable, Sendable {
    let state: NovelSessionBottomFollowState
    let commands: [NovelSessionBottomFollowCommand]
}

enum NovelSessionBottomFollowPolicy {
    static let terminalQuietDelay: TimeInterval = 0.4

    static func reduce(
        state: NovelSessionBottomFollowState,
        event: NovelSessionBottomFollowEvent,
        followEnabled: Bool = true
    ) -> NovelSessionBottomFollowTransition {
        var next = state
        var commands: [NovelSessionBottomFollowCommand] = []

        switch event {
        case .reset:
            next = NovelSessionBottomFollowState()

        case .initialRowsPresented(let hasRows):
            guard next.mode == .awaitingInitialRows else { break }
            next.mode = .followingBottom
            if hasRows { commands.append(.anchorBottom) }

        case .streamStarted:
            next.mode = .followingBottom
            setBottomButton(false, state: &next, commands: &commands)
            commands.append(.anchorBottom)

        case .streamDelta:
            break

        case .measuredStreamGrowth(let isAtBottom):
            guard followEnabled else {
                handleDisabledMeasuredGrowth(
                    isAtBottom: isAtBottom,
                    state: &next,
                    commands: &commands
                )
                break
            }
            switch next.mode {
            case .followingBottom:
                // 2026-07-26 撤锚更正:`.sizeChanges` 底锚已被真机录屏(15fps 逐帧对齐,
                // 连续三次 −391/−398/−385px 结构性跳变)推翻——它在生产的
                // ParagraphUIView 异步增量 TextKit 布局路径下并不能同步吸收增长
                // (合成的 Color.frame(height:) 单次布局 pass 测不到这条路径)。
                // measured-geometry 回调
                // 重新成为流式跟随底部的唯一写者;命令必须是 animated:false——
                // 执行侧 NovelSessionView.scrollToBottomWithoutAnimation() 用
                // Transaction(animation: nil) 显式禁用动画,不经过
                // startExplicitBottomAnimation() 的 0.2s easeOut。这正是
                // PROJECT_STATE 2026-07-21 记录的「先欠账、再用 0.08s 动画追回」
                // 53pt 回归不能复发的关键:那次回归的病根不是「measured growth 驱动
                // 跟随」本身,而是「给语义为瞬时到位的自动跟随包了动画」。
                commands.append(.followBottom(animated: false))
            case .settlingTerminal:
                next.mode = .followingBottom
                commands.append(.followBottom(animated: false))
            case .awaitingInitialRows, .browsingHistory:
                break
            }

        case .measuredTerminalGrowth(let isAtBottom):
            guard followEnabled else {
                handleDisabledMeasuredGrowth(
                    isAtBottom: isAtBottom,
                    state: &next,
                    commands: &commands
                )
                break
            }
            scheduleTerminalSettle(state: &next, commands: &commands)

        case .staticContentGrowth(let isAtBottom):
            // 静态排版增长不拥有滚动：不发滚动命令、不改模式，只让底部按钮
            // 反映真实的到底状态，用户始终保有主动回底的入口。
            guard next.mode != .awaitingInitialRows else { break }
            setBottomButton(!isAtBottom, state: &next, commands: &commands)

        case .userDragBegan(let isAtBottom):
            next.mode = .browsingHistory
            setBottomButton(!isAtBottom, state: &next, commands: &commands)

        case .userDragEnded(let isAtBottom):
            if isAtBottom, followEnabled {
                next.mode = .followingBottom
                setBottomButton(false, state: &next, commands: &commands)
                commands.append(.followBottom(animated: false))
            } else {
                next.mode = .browsingHistory
                setBottomButton(!isAtBottom, state: &next, commands: &commands)
            }

        case .viewportChanged(let isAtBottom):
            switch next.mode {
            case .followingBottom, .settlingTerminal:
                if !isAtBottom {
                    if followEnabled {
                        commands.append(.followBottom(animated: false))
                    } else {
                        next.mode = .browsingHistory
                        setBottomButton(true, state: &next, commands: &commands)
                    }
                } else {
                    // staticContentGrowth 可能在跟随态亮过按钮；几何回底后必须
                    // 收掉，保证按钮始终反映真实到底状态（无按钮时是无操作）。
                    setBottomButton(false, state: &next, commands: &commands)
                }
            case .browsingHistory:
                // Passive geometry cannot resume follow. Only the user's drag ending at
                // bottom, or the explicit bottom command, owns that transition.
                setBottomButton(!isAtBottom, state: &next, commands: &commands)
            case .awaitingInitialRows:
                break
            }

        case .explicitBottomRequested:
            next.mode = .followingBottom
            setBottomButton(false, state: &next, commands: &commands)
            commands.append(.followBottom(animated: true))

        case .terminalReached, .terminalLayoutChanged:
            guard followEnabled else { break }
            scheduleTerminalSettle(state: &next, commands: &commands)

        case .terminalQuietElapsed(let token):
            guard next.mode == .settlingTerminal(token: token) else { break }
            next.mode = .followingBottom
            if followEnabled {
                commands.append(.followBottom(animated: false))
            }
        }

        return NovelSessionBottomFollowTransition(state: next, commands: commands)
    }
}

private extension NovelSessionBottomFollowPolicy {
    static func handleDisabledMeasuredGrowth(
        isAtBottom: Bool,
        state: inout NovelSessionBottomFollowState,
        commands: inout [NovelSessionBottomFollowCommand]
    ) {
        switch state.mode {
        case .followingBottom, .settlingTerminal:
            if !isAtBottom {
                state.mode = .browsingHistory
                setBottomButton(true, state: &state, commands: &commands)
            }
        case .browsingHistory:
            setBottomButton(!isAtBottom, state: &state, commands: &commands)
        case .awaitingInitialRows:
            break
        }
    }

    static func scheduleTerminalSettle(
        state: inout NovelSessionBottomFollowState,
        commands: inout [NovelSessionBottomFollowCommand]
    ) {
        switch state.mode {
        case .followingBottom, .settlingTerminal:
            state.nextSettleToken &+= 1
            let token = state.nextSettleToken
            state.mode = .settlingTerminal(token: token)
            // driver 激活时由它逐帧钉底（generationTerminated），视图层不再
            // 需要 quietSettle 定时器——driver 的 idleStopInterval(0.3s) 静默
            // 交还 + viewportChanged idle 近底重锚兜底晚到布局。
            commands.append(.terminateGeneration)
            commands.append(.scheduleTerminalQuietSettle(
                token: token,
                delay: terminalQuietDelay
            ))
        case .awaitingInitialRows, .browsingHistory:
            break
        }
    }

    static func setBottomButton(
        _ visible: Bool,
        state: inout NovelSessionBottomFollowState,
        commands: inout [NovelSessionBottomFollowCommand]
    ) {
        guard state.showsBottomButton != visible else { return }
        state.showsBottomButton = visible
        commands.append(.setBottomButton(visible))
    }
}
