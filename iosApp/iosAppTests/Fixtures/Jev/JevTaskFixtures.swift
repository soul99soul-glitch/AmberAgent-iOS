import Foundation

// MARK: - Jev Phase 3 模型调度对照语料（C11 / Phase B 任务侧）
//
// 20 条有代表性的子任务样本，每条带金标准标签：任务真实需要的能力
// （视觉/工具/上下文容量）、池中理想与可接受模型、无合适候选（noFit）情形。
// 用途：Key 到位后，同一语料跑 baseline（现有选择规则）与 Jev 调度做对照；
// 离线阶段先固定语料与裁决器，并用参考路由器验证语料自洽。
//
// 注意：现有池选择规则（负载/轮转）是任务无关的，不存在"逐任务 baseline 选择"
// 可钉；baseline 分数 = 任务无关规则在本语料上的裁决结果，由 runner 测试记录。

/// 池模型能力描述（离线 fixture，不依赖 KMP 类型）。
struct SubAgentModelFixture: Equatable {
    var id: String
    var vision: Bool
    var tools: Bool
    var contextTokens: Int
    /// 成本档：1 便宜 … 3 贵。路由收益口径的一部分。
    var costTier: Int
}

/// 子任务样本。`idealModelId` 为 nil 表示无合适候选（noFit），
/// 正确行为是弃权和回退主流程，而不是硬选一个。
struct SubAgentTaskFixture: Equatable {
    enum Category: String, CaseIterable {
        case textRework, codeFix, analysis, vision, longContext, toolUse, noFit
    }
    var id: String
    var category: Category
    var taskText: String
    var needsVision: Bool
    var needsTools: Bool
    var minContextTokens: Int
    /// 池中最适配模型；noFit 任务为 nil。
    var idealModelId: String?
    /// 可接受（不理想但不犯错）的模型集合。
    var acceptableModelIds: Set<String>
}

/// 裁决结果：路由函数的选择落在哪一档。
enum SubAgentRoutingVerdict: String, Equatable {
    case ideal              // 选中理想模型
    case acceptable         // 选中可接受模型
    case wrongSelection     // 选了不满足硬约束或未列名的模型 / noFit 任务硬选
    case correctAbstention  // noFit 任务正确弃权
    case missedSelection    // 普通任务弃权（有合适候选却没选）
}

enum JevSubAgentCorpus {

    /// 固定 6 模型池：覆盖视觉/工具/上下文/成本四轴差异。
    static let pool: [SubAgentModelFixture] = [
        SubAgentModelFixture(id: "lite-notools", vision: false, tools: false, contextTokens: 16_000, costTier: 1),
        SubAgentModelFixture(id: "swift-cheap", vision: false, tools: true, contextTokens: 32_000, costTier: 1),
        SubAgentModelFixture(id: "swift-mid", vision: false, tools: true, contextTokens: 128_000, costTier: 2),
        SubAgentModelFixture(id: "vision-pro", vision: true, tools: true, contextTokens: 128_000, costTier: 3),
        SubAgentModelFixture(id: "analysis-deep", vision: false, tools: true, contextTokens: 256_000, costTier: 3),
        SubAgentModelFixture(id: "longctx", vision: false, tools: true, contextTokens: 1_000_000, costTier: 3),
    ]

    /// 20 条任务：文本整理 3 / 代码修复 4 / 复杂分析 4 / 视觉 3 / 长上下文 3 /
    /// 工具需求 2 / 无合适候选 1。
    static let tasks: [SubAgentTaskFixture] = [
        // —— 文本整理（轻量，便宜模型即可）——
        .init(id: "tr-1", category: .textRework, taskText: "把这段会议记录整理成三条待办",
              needsVision: false, needsTools: false, minContextTokens: 4_000,
              idealModelId: "swift-cheap", acceptableModelIds: ["swift-mid", "lite-notools"]),
        .init(id: "tr-2", category: .textRework, taskText: "把下面的中文要点翻译成英文并保持术语一致",
              needsVision: false, needsTools: false, minContextTokens: 8_000,
              idealModelId: "swift-cheap", acceptableModelIds: ["swift-mid", "lite-notools"]),
        .init(id: "tr-3", category: .textRework, taskText: "润色这封邮件，语气更正式",
              needsVision: false, needsTools: false, minContextTokens: 4_000,
              idealModelId: "lite-notools", acceptableModelIds: ["swift-cheap", "swift-mid"]),
        // —— 代码修复（需要工具与一定上下文）——
        .init(id: "cf-1", category: .codeFix, taskText: "修复这个 Swift 函数的空指针崩溃并跑测试",
              needsVision: false, needsTools: true, minContextTokens: 32_000,
              idealModelId: "swift-cheap", acceptableModelIds: ["swift-mid", "analysis-deep"]),
        .init(id: "cf-2", category: .codeFix, taskText: "排查这个 Gradle 构建脚本为什么缓存失效",
              needsVision: false, needsTools: true, minContextTokens: 64_000,
              idealModelId: "swift-mid", acceptableModelIds: ["analysis-deep", "longctx"]),
        .init(id: "cf-3", category: .codeFix, taskText: "重构这个 800 行 ViewController 的依赖注入",
              needsVision: false, needsTools: true, minContextTokens: 128_000,
              idealModelId: "swift-mid", acceptableModelIds: ["analysis-deep", "longctx"]),
        .init(id: "cf-4", category: .codeFix, taskText: "修复并发竞态：需要读懂整个模块的状态机",
              needsVision: false, needsTools: true, minContextTokens: 200_000,
              idealModelId: "analysis-deep", acceptableModelIds: ["longctx"]),
        // —— 复杂分析（深推理 + 大上下文）——
        .init(id: "an-1", category: .analysis, taskText: "对比这三个架构方案的可靠性并给出裁决",
              needsVision: false, needsTools: false, minContextTokens: 64_000,
              idealModelId: "analysis-deep", acceptableModelIds: ["swift-mid", "longctx"]),
        .init(id: "an-2", category: .analysis, taskText: "分析这份财报电话会纪要的风险点",
              needsVision: false, needsTools: false, minContextTokens: 100_000,
              idealModelId: "analysis-deep", acceptableModelIds: ["swift-mid", "longctx"]),
        .init(id: "an-3", category: .analysis, taskText: "评审这份 40 页协议草案的条款冲突",
              needsVision: false, needsTools: false, minContextTokens: 240_000,
              idealModelId: "analysis-deep", acceptableModelIds: ["longctx"]),
        .init(id: "an-4", category: .analysis, taskText: "从日志归纳崩溃共性并给出修复优先级",
              needsVision: false, needsTools: true, minContextTokens: 128_000,
              idealModelId: "analysis-deep", acceptableModelIds: ["swift-mid", "longctx"]),
        // —— 视觉任务（硬约束：vision）——
        .init(id: "vi-1", category: .vision, taskText: "描述这张截图里的 UI 错位问题",
              needsVision: true, needsTools: false, minContextTokens: 16_000,
              idealModelId: "vision-pro", acceptableModelIds: []),
        .init(id: "vi-2", category: .vision, taskText: "对照设计稿检查这个页面的间距是否一致",
              needsVision: true, needsTools: false, minContextTokens: 32_000,
              idealModelId: "vision-pro", acceptableModelIds: []),
        .init(id: "vi-3", category: .vision, taskText: "读取这张白板照片里的流程图并转成文字",
              needsVision: true, needsTools: false, minContextTokens: 32_000,
              idealModelId: "vision-pro", acceptableModelIds: []),
        // —— 长上下文（硬约束：容量）——
        .init(id: "lc-1", category: .longContext, taskText: "通读这本 20 万字小说草稿并列出伏笔未回收清单",
              needsVision: false, needsTools: false, minContextTokens: 400_000,
              idealModelId: "longctx", acceptableModelIds: []),
        .init(id: "lc-2", category: .longContext, taskText: "把整季聊天记录（约 50 万 token）按主题归档",
              needsVision: false, needsTools: true, minContextTokens: 600_000,
              idealModelId: "longctx", acceptableModelIds: []),
        .init(id: "lc-3", category: .longContext, taskText: "在 300 页 PDF 里找出所有数字不一致处",
              needsVision: false, needsTools: false, minContextTokens: 300_000,
              idealModelId: "longctx", acceptableModelIds: []),
        // —— 工具需求（硬约束：tools）——
        .init(id: "tu-1", category: .toolUse, taskText: "查一下明天的天气并写进备忘录",
              needsVision: false, needsTools: true, minContextTokens: 8_000,
              idealModelId: "swift-cheap", acceptableModelIds: ["swift-mid"]),
        .init(id: "tu-2", category: .toolUse, taskText: "把这个网页的正文抓下来存档",
              needsVision: false, needsTools: true, minContextTokens: 32_000,
              idealModelId: "swift-cheap", acceptableModelIds: ["swift-mid", "vision-pro"]),
        // —— 无合适候选：需要实时音频通话能力，池中无人具备 ——
        .init(id: "nf-1", category: .noFit, taskText: "帮我实时同声传译这通电话",
              needsVision: false, needsTools: false, minContextTokens: 8_000,
              idealModelId: nil, acceptableModelIds: []),
    ]

    /// 硬约束过滤：任务需要的模态/工具/容量，模型必须全部满足。
    static func satisfiesHardConstraints(_ model: SubAgentModelFixture, task: SubAgentTaskFixture) -> Bool {
        if task.needsVision && !model.vision { return false }
        if task.needsTools && !model.tools { return false }
        if model.contextTokens < task.minContextTokens { return false }
        return true
    }

    /// 裁决一次选择。`selection` 为 nil 表示路由弃权。
    static func verdict(task: SubAgentTaskFixture, selection: String?) -> SubAgentRoutingVerdict {
        if task.idealModelId == nil {
            return selection == nil ? .correctAbstention : .wrongSelection
        }
        guard let selection else { return .missedSelection }
        if selection == task.idealModelId { return .ideal }
        if task.acceptableModelIds.contains(selection) {
            // 可接受集仍须过硬约束（fixture 自洽由测试保证，这里按运行时口径再查一次）。
            if let model = pool.first(where: { $0.id == selection }), satisfiesHardConstraints(model, task: task) {
                return .acceptable
            }
            return .wrongSelection
        }
        return .wrongSelection
    }
}
