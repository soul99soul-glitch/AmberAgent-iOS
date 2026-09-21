import XCTest
@testable import iosApp

// IOSJevBaselineCorpusTests（C11 / Phase B）：离线对照语料的自洽性与可用性证明。
//
// 子任务语料：金标准标签自洽（理想/可接受模型存在且过硬约束）、裁决器语义、
// 参考路由器（硬约束过滤+最便宜优先）钉死基线分数快照——Key 到位后同一语料
// 跑 Jev 调度对照这组数字。
//
// 网页语料：状态机自洽（转移表引用合法、动作词表与真实循环一致、type_draft
// 步骤带值）、可解任务用理想策略真实执行到完成、完成核验器在初始页不误判、
// completionMarker 只在完成态出现、不可解任务有界 BFS 不完成、懒惰策略被
// 草稿前置条件拒绝。语料离线可重放：两次运行轨迹逐字节一致。

final class IOSJevBaselineCorpusTests: XCTestCase {

    // MARK: - 子任务语料自洽

    func testTaskCorpusIsSelfConsistent() {
        let tasks = JevSubAgentCorpus.tasks
        XCTAssertEqual(tasks.count, 20)
        XCTAssertEqual(Set(tasks.map(\.id)).count, 20, "任务 id 唯一")
        // 每个类别至少一条（含 noFit）。
        for category in SubAgentTaskFixture.Category.allCases {
            XCTAssertTrue(tasks.contains { $0.category == category }, "缺类别 \(category)")
        }
        let poolIds = Set(JevSubAgentCorpus.pool.map(\.id))
        XCTAssertEqual(poolIds.count, JevSubAgentCorpus.pool.count, "池模型 id 唯一")
        for task in tasks {
            if let ideal = task.idealModelId {
                guard let model = JevSubAgentCorpus.pool.first(where: { $0.id == ideal }) else {
                    return XCTFail("\(task.id) 理想模型 \(ideal) 不在池中")
                }
                XCTAssertTrue(
                    JevSubAgentCorpus.satisfiesHardConstraints(model, task: task),
                    "\(task.id) 理想模型必须过硬约束"
                )
            } else {
                XCTAssertEqual(task.category, .noFit, "只有 noFit 任务允许无理想模型")
                XCTAssertTrue(task.acceptableModelIds.isEmpty)
            }
            for acceptable in task.acceptableModelIds {
                guard let model = JevSubAgentCorpus.pool.first(where: { $0.id == acceptable }) else {
                    return XCTFail("\(task.id) 可接受模型 \(acceptable) 不在池中")
                }
                XCTAssertTrue(
                    JevSubAgentCorpus.satisfiesHardConstraints(model, task: task),
                    "\(task.id) 可接受模型 \(acceptable) 必须过硬约束"
                )
            }
        }
    }

    // MARK: - 裁决器语义

    func testVerdictSemantics() {
        let task = JevSubAgentCorpus.tasks.first { $0.id == "cf-1" }! // ideal swift-cheap
        XCTAssertEqual(JevSubAgentCorpus.verdict(task: task, selection: "swift-cheap"), .ideal)
        XCTAssertEqual(JevSubAgentCorpus.verdict(task: task, selection: "swift-mid"), .acceptable)
        XCTAssertEqual(JevSubAgentCorpus.verdict(task: task, selection: "lite-notools"), .wrongSelection, "无工具模型做代码修复")
        XCTAssertEqual(JevSubAgentCorpus.verdict(task: task, selection: "ghost"), .wrongSelection, "未知 id")
        XCTAssertEqual(JevSubAgentCorpus.verdict(task: task, selection: nil), .missedSelection)

        let noFit = JevSubAgentCorpus.tasks.first { $0.id == "nf-1" }!
        XCTAssertEqual(JevSubAgentCorpus.verdict(task: noFit, selection: nil), .correctAbstention)
        XCTAssertEqual(JevSubAgentCorpus.verdict(task: noFit, selection: "swift-cheap"), .wrongSelection, "noFit 硬选即错")
    }

    // MARK: - 参考路由器 baseline（钉死分数快照）

    /// 参考路由：硬约束过滤后取最便宜（并列取 id 字典序小者）。任务无关规则的
    /// 代表实现——它不是 Jev，只是语料的可重放参照系。
    private func referenceRouter(_ task: SubAgentTaskFixture) -> String? {
        JevSubAgentCorpus.pool
            .filter { JevSubAgentCorpus.satisfiesHardConstraints($0, task: task) }
            .sorted {
                if $0.costTier != $1.costTier { return $0.costTier < $1.costTier }
                return $0.id < $1.id
            }
            .first?.id
    }

    func testReferenceRouterBaselineScoreIsPinned() {
        var counts: [SubAgentRoutingVerdict: Int] = [:]
        for task in JevSubAgentCorpus.tasks {
            let verdict = JevSubAgentCorpus.verdict(task: task, selection: referenceRouter(task))
            counts[verdict, default: 0] += 1
        }
        // 钉死参照系分数：ideal 14 / acceptable 5 / wrongSelection 1（nf-1 语义
        // 无解但能力过滤放行了 lite-notools——正是金标准要暴露的基线盲区）。
        XCTAssertEqual(counts[.ideal], 14)
        XCTAssertEqual(counts[.acceptable], 5)
        XCTAssertEqual(counts[.wrongSelection], 1)
        XCTAssertNil(counts[.missedSelection])
        XCTAssertNil(counts[.correctAbstention])
    }

    func testTaskCorpusIsReplayable() {
        let run1 = JevSubAgentCorpus.tasks.map { JevSubAgentCorpus.verdict(task: $0, selection: referenceRouter($0)) }
        let run2 = JevSubAgentCorpus.tasks.map { JevSubAgentCorpus.verdict(task: $0, selection: referenceRouter($0)) }
        XCTAssertEqual(run1, run2, "同一语料两次运行必须一致")
    }

    // MARK: - 网页语料自洽

    /// 真实循环动作词表（与 IOSJevWebMountLoopService.actionWhitelist 一致）。
    private let actionVocabulary: Set<String> = ["scroll", "select", "click_nav", "type_draft", "submit_readonly_search"]

    func testWebCorpusIsSelfConsistent() {
        let all = JevWebTaskCorpus.all
        XCTAssertEqual(all.count, 20)
        XCTAssertEqual(Set(all.map(\.id)).count, 20, "任务 id 唯一")
        let solvableCount = all.filter { if case .solvable = $0.solvability { return true }; return false }.count
        XCTAssertEqual(solvableCount, 17, "17 可解 + 3 不可解（停滞/登录墙/验证码）")
        for fixture in all {
            XCTAssertFalse(fixture.goal.isEmpty)
            XCTAssertFalse(fixture.completionMarker.isEmpty)
            XCTAssertFalse(fixture.pages.isEmpty, "\(fixture.id) 至少一页")
            // 动作词表与真实循环一致：allowedActions 与转移表都不得超白名单。
            XCTAssertTrue(fixture.allowedActions.isSubset(of: actionVocabulary), "\(fixture.id) allowedActions 超出真实词表")
            for transition in fixture.transitions {
                XCTAssertTrue(actionVocabulary.contains(transition.action), "\(fixture.id) 转移动作 \(transition.action) 不在词表")
                XCTAssertTrue(fixture.allowedActions.contains(transition.action), "\(fixture.id) 转移动作未获允许")
                XCTAssertTrue(fixture.pages.indices.contains(transition.fromPage), "\(fixture.id) 转移起点越界")
                XCTAssertTrue(fixture.pages.indices.contains(transition.toPage), "\(fixture.id) 转移终点越界")
                if let elementId = transition.elementId {
                    XCTAssertTrue(
                        fixture.pages[transition.fromPage].elements.contains { $0.id == elementId },
                        "\(fixture.id) 转移引用的元素 \(elementId) 不在起始页"
                    )
                    for required in transition.requiresTyped {
                        XCTAssertTrue(
                            fixture.pages[transition.fromPage].elements.contains { $0.id == required },
                            "\(fixture.id) 前置 typed 元素 \(required) 不在起始页"
                        )
                    }
                }
            }
            if case .solvable(let policy) = fixture.solvability {
                XCTAssertFalse(policy.isEmpty, "\(fixture.id) 可解任务必须带理想策略")
                for step in policy {
                    XCTAssertTrue(actionVocabulary.contains(step.action), "\(fixture.id) 理想策略动作不在词表")
                    if step.action == "type_draft" {
                        XCTAssertNotNil(step.value, "\(fixture.id) type_draft 步骤必须带值（真实循环缺值不出候选）")
                    }
                }
            }
        }
    }

    // MARK: - 可解性证明（理想策略真实执行）

    func testSolvableTasksCompleteUnderIdealPolicy() {
        for fixture in JevWebTaskCorpus.all {
            guard case .solvable(let policy) = fixture.solvability else { continue }
            let world = WebTaskWorld(fixture: fixture)
            XCTAssertFalse(world.isComplete, "\(fixture.id) 初始页不得已完成（核验器防误判）")
            for (offset, step) in policy.enumerated() {
                let result = world.execute(action: step.action, elementId: step.elementId)
                guard case .applied = result else {
                    return XCTFail("\(fixture.id) 理想策略第 \(offset + 1) 步未应用：\(step.action) → \(result)")
                }
            }
            XCTAssertTrue(world.isComplete, "\(fixture.id) 理想策略执行完必须完成")
        }
    }

    // MARK: - completionMarker 契约：只在完成态出现

    func testCompletionMarkerAppearsOnlyAtCompletion() {
        for fixture in JevWebTaskCorpus.all {
            let pageText: (WebTaskFixture.Page) -> String = { page in
                ([page.url, page.title] + page.elements.map(\.label)).joined(separator: "\n")
            }
            switch fixture.solvability {
            case .solvable(let policy):
                let world = WebTaskWorld(fixture: fixture)
                // 初始页与每个中途落地页都不得含 marker。
                XCTAssertFalse(pageText(world.currentPage).contains(fixture.completionMarker),
                               "\(fixture.id) 初始页含 marker，wire 层会误判完成")
                for (offset, step) in policy.enumerated() {
                    _ = world.execute(action: step.action, elementId: step.elementId)
                    let isLast = offset == policy.count - 1
                    if isLast {
                        XCTAssertTrue(world.isComplete, "\(fixture.id) 末步后必须完成")
                        XCTAssertTrue(pageText(world.currentPage).contains(fixture.completionMarker),
                                      "\(fixture.id) 完成态页面不含 marker，wire 层核验不到")
                    } else {
                        XCTAssertFalse(pageText(world.currentPage).contains(fixture.completionMarker),
                                       "\(fixture.id) 中途页（第 \(offset + 1) 步后）含 marker")
                    }
                }
            case .unsolvable:
                for page in fixture.pages {
                    XCTAssertFalse(pageText(page).contains(fixture.completionMarker),
                                   "\(fixture.id) 不可解任务的任何页面都不得含 marker")
                }
            }
        }
    }

    // MARK: - 不可解任务：有界穷举不完成

    func testUnsolvableTasksNeverCompleteWithinBoundedWalk() {
        for fixture in JevWebTaskCorpus.all {
            guard fixture.solvability == .unsolvable else { continue }
            // 标准 BFS：visited 按页去重（世界状态完全由 pageIndex 决定）+
            // 深度上限 6 双重保证终止；任何可达状态都不得触发完成核验。
            var queue: [(world: WebTaskWorld, depth: Int)] = [(WebTaskWorld(fixture: fixture), 0)]
            var visited = Set<Int>()
            while let (world, depth) = queue.first {
                queue.removeFirst()
                guard depth <= 6, visited.insert(world.pageIndex).inserted else { continue }
                XCTAssertFalse(world.isComplete, "\(fixture.id) 在 \(world.currentPage.url) 误判完成")
                for transition in fixture.transitions where transition.fromPage == world.pageIndex {
                    let next = WebTaskWorld(fixture: fixture)
                    for (action, elementId) in world.executedActions { _ = next.execute(action: action, elementId: elementId) }
                    _ = next.execute(action: transition.action, elementId: transition.elementId)
                    queue.append((next, depth + 1))
                }
            }
        }
    }

    // MARK: - 草稿前置条件：懒惰策略不得分

    func testDraftTasksRejectLazyPolicy() {
        // 直接点保存（不填任何字段）必须 failed 且不完成。
        let lazy = JevWebTaskCorpus.makeWorld("multi-field-draft")
        guard case .failed = lazy.execute(action: "click_nav", elementId: "save") else {
            return XCTFail("未填字段点保存必须 failed")
        }
        XCTAssertFalse(lazy.isComplete)

        // 只填一个字段也不够。
        let partial = JevWebTaskCorpus.makeWorld("multi-field-draft")
        _ = partial.execute(action: "type_draft", elementId: "title")
        guard case .failed = partial.execute(action: "click_nav", elementId: "save") else {
            return XCTFail("只填标题点保存必须 failed")
        }
        XCTAssertFalse(partial.isComplete)

        let lazyPreview = JevWebTaskCorpus.makeWorld("draft-and-preview")
        guard case .failed = lazyPreview.execute(action: "click_nav", elementId: "prev") else {
            return XCTFail("未打字点预览必须 failed")
        }
        XCTAssertFalse(lazyPreview.isComplete)
    }

    // MARK: - 世界语义

    func testWorldRejectsUnknownActionAndStaleElement() {
        let world = JevWebTaskCorpus.makeWorld("search-then-open")
        guard case .failed = world.execute(action: "click_nav", elementId: "ghost") else {
            return XCTFail("不存在的元素必须 failed")
        }
        guard case .failed = world.execute(action: "delete", elementId: "q") else {
            return XCTFail("转移表外的动作必须 failed")
        }
        XCTAssertEqual(world.revision, 1, "失败动作不得推进 revision")

        // 元素身份漂移：旧 id 在新页面必然失败。
        let churn = JevWebTaskCorpus.makeWorld("identity-churn")
        guard case .applied = churn.execute(action: "scroll", elementId: nil) else { return XCTFail("scroll 应应用") }
        guard case .failed = churn.execute(action: "click_nav", elementId: "old-shoe") else {
            return XCTFail("旧 id 在新页面必须 failed（禁止复用旧目标）")
        }
        guard case .applied = churn.execute(action: "click_nav", elementId: "new-shoe") else {
            return XCTFail("新 id 应应用")
        }
        XCTAssertTrue(churn.isComplete)
    }

    // MARK: - 语料可重放

    func testWebCorpusIsReplayable() {
        for fixture in JevWebTaskCorpus.all {
            guard case .solvable(let policy) = fixture.solvability else { continue }
            let trace1 = runTrace(fixture: fixture, policy: policy)
            let trace2 = runTrace(fixture: fixture, policy: policy)
            XCTAssertEqual(trace1, trace2, "\(fixture.id) 两次运行轨迹必须一致")
        }
    }

    private func runTrace(fixture: WebTaskFixture, policy: [WebTaskIdealStep]) -> [String] {
        let world = WebTaskWorld(fixture: fixture)
        var trace = ["\(world.currentPage.url)#\(world.revision)"]
        for step in policy {
            let result = world.execute(action: step.action, elementId: step.elementId)
            trace.append("\(step.action):\(step.elementId ?? "-")→\(result)")
            trace.append("\(world.currentPage.url)#\(world.revision)")
        }
        trace.append("complete=\(world.isComplete)")
        return trace
    }
}
