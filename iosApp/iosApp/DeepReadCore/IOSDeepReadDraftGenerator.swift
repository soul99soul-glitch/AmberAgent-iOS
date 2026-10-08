import Foundation
@preconcurrency import Shared

enum IOSDeepReadDraftGenerator {
    /// Resolves the provider setting the Deep Read pipeline should use, by
    /// honoring the user's actually-selected provider — NOT rebuilding an
    /// OpenAI-shaped setting from scratch. This is the parity fix for
    /// `deepread.provider_real`: when Claude is selected, the pipeline must
    /// dispatch through a `ProviderSetting.Claude` (native `/messages`), and
    /// `OpenAIKmpProviderAdapter.generateText` already downcasts + dispatches on
    /// the sealed type. Reusing the selected setting (mirroring how chat resolves
    /// via `ChatProviderConfiguration.provider(for:providers:)`) avoids the
    /// silent `/chat/completions`-on-Claude gap. (locked_decision: no
    /// ProviderExecutionContext; only the (provider, model, params) tuple.)
    ///
    /// The caller passes the selected provider verbatim (chat already resolved
    /// it); this returns it unchanged so the sealed type flows to the adapter.
    /// A nil return signals "no usable provider" → the caller falls back to the
    /// deterministic offline draft (honest degradation).
    static func resolveProviderSetting(selected: ProviderSetting?) -> ProviderSetting? {
        guard let selected else { return nil }
        // Pass the selected setting through by sealed type so the adapter
        // dispatches to the right native endpoint. We clone into a clean id to
        // avoid mutating the shared registry object, but preserve the type +
        // credentials + endpoint. descriptionText/shortDescriptionText are
        // abstract on the base ProviderSetting, read once here.
        let descriptionText = selected.descriptionText
        let shortDescriptionText = selected.shortDescriptionText
        switch selected {
        case let openAI as ProviderSetting.OpenAI:
            return ProviderSetting.OpenAI(
                id: KotlinUuid.companion.random(),
                enabled: openAI.enabled,
                name: openAI.name,
                models: openAI.models,
                balanceOption: openAI.balanceOption,
                builtIn: openAI.builtIn,
                descriptionText: descriptionText,
                shortDescriptionText: shortDescriptionText,
                apiKey: openAI.apiKey,
                baseUrl: openAI.baseUrl,
                chatCompletionsPath: openAI.chatCompletionsPath,
                useResponseApi: openAI.useResponseApi,
                authMode: openAI.authMode,
                brand: openAI.brand
            )
        case let claude as ProviderSetting.Claude:
            return ProviderSetting.Claude(
                id: KotlinUuid.companion.random(),
                enabled: claude.enabled,
                name: claude.name,
                models: claude.models,
                balanceOption: claude.balanceOption,
                builtIn: claude.builtIn,
                descriptionText: descriptionText,
                shortDescriptionText: shortDescriptionText,
                apiKey: claude.apiKey,
                baseUrl: claude.baseUrl,
                promptCaching: claude.promptCaching
            )
        default:
            // Unknown/non-OpenAI-compatible sealed type → none usable. The caller
            // degrades to the deterministic offline draft (interim safeguard).
            return nil
        }
    }

    static func generate(task: IOSDeepReadTask, now: Date = Date()) -> String {
        let sources = task.sources.filter { $0.metadata["scrape_status"] != "failed" }
        let date = IOSDeepReadDateFormatters.detail.string(from: now)
        let grouped = Dictionary(grouping: sources, by: \.kind)

        var lines: [String] = []
        lines.append("# \(task.title)")
        lines.append("")
        lines.append(date)
        lines.append("")
        lines.append("## 摘要")
        lines.append(summary(from: sources))
        lines.append("")
        lines.append("## 关键来源")
        for source in sources.prefix(8) {
            lines.append("- **\(source.kind.title)｜\(source.title)**：\(excerpt(source.content, limit: 220))")
            if let url = source.url, !url.isEmpty {
                lines.append("  \(url)")
            }
        }
        lines.append("")
        lines.append("## 脉络")
        lines.append(narrative(from: sources))
        lines.append("")
        lines.append("## 分析")
        lines.append(analysis(from: sources, templateId: task.templateId))
        lines.append("")
        lines.append("## 后续阅读")
        let links = sources.compactMap { source -> String? in
            guard let url = source.url, !url.isEmpty else { return nil }
            return "- [\(source.title)](\(url))"
        }
        lines.append(contentsOf: links.isEmpty ? ["- 当前来源没有可打开链接。"] : links)
        if grouped[.file]?.contains(where: { $0.metadata["truncated"] == "true" }) == true {
            lines.append("")
            lines.append("> 文件内容已截断；如需更完整分析，请缩小文件或分段导入。")
        }
        return lines.joined(separator: "\n")
    }

    private static func summary(from sources: [IOSDeepReadSource]) -> String {
        let head = sources
            .prefix(3)
            .map { excerpt($0.content, limit: 160) }
            .filter { !$0.isEmpty }
        guard !head.isEmpty else { return "当前没有足够文本形成摘要。" }
        return "这次深度阅读基于\(sources.count)个真实来源整理：\(head.joined(separator: " "))"
    }

    private static func narrative(from sources: [IOSDeepReadSource]) -> String {
        sources
            .prefix(5)
            .enumerated()
            .map { index, source in
                "\(index + 1). \(source.title)：\(excerpt(source.content, limit: 180))"
            }
            .joined(separator: "\n")
    }

    private static func analysis(from sources: [IOSDeepReadSource], templateId: String) -> String {
        let sourceKinds = Set(sources.map(\.kind))
        var points: [String] = []
        if sourceKinds.contains(.searchResult) {
            points.append("- 搜索来源适合交叉核对，但摘要可能受搜索页片段限制。")
        }
        if sourceKinds.contains(.conversation) {
            points.append("- 会话来源能保留上下文意图，适合提炼待办、决策和未解决问题。")
        }
        if sourceKinds.contains(.file) {
            points.append("- 文件来源来自本机显式选择；不可读或扫描图片不会被假装 OCR。")
        }
        if sourceKinds.contains(.webMount) {
            points.append("- 站点来源只读取当前前台页面正文，不自动登录或跨站抓取。")
        }
        if sourceKinds.contains(.hotTopic) {
            points.append("- 热榜来源来自公开榜单；网页正文抓取失败时只保留榜单标题、排名、热度和链接，不补写未读取内容。")
        }
        if points.isEmpty {
            points.append("- 当前结论主要来自用户提供文本；建议补充搜索或文件来源做交叉验证。")
        }
        if templateId == IOSDeepReadTemplate.analysis.id {
            points.append("- 下一步：标记需要验证的事实、补齐缺失来源，再决定是否把结果发回聊天继续推演。")
        }
        return points.joined(separator: "\n")
    }

    private static func excerpt(_ text: String, limit: Int) -> String {
        IOSDeepReadSourceNormalizer.cleanMultiline(text).deepReadPrefixString(limit)
    }

    // MARK: - LLM-driven generation (Android DeepReadAgentRunManager parity)
    //
    // The deterministic `generate(task:)` above is an offline fallback. This
    // async variant runs real LLM synthesis per section (overview → narrative →
    // analysis → extended reading), mirroring Android's DeepReadAgentRunManager
    // stage pipeline. The launcher requires a usable configured model before
    // starting. Real generation quality still needs a live-provider check.

    /// Generates a deep-read draft via real LLM synthesis. Each section is one
    /// model call seeded with the sources + prior-section output (sequential,
    /// like Android). Generation failures are reported by generateViaLLMResult.
    static func generateViaLLM(
        task: IOSDeepReadTask,
        providerSetting: ProviderSetting,
        model: Model,
        provider: IOSAgentTextProvider = OpenAIKmpProviderAdapter(),
        now: Date = Date()
    ) async -> String {
        await generateViaLLMResult(
            task: task,
            providerSetting: providerSetting,
            model: model,
            provider: provider,
            now: now
        ).markdown
    }

    /// Structured result of an LLM-driven generation run, exposing whether the
    /// run honestly failed (every stage threw OR produced empty/whitespace-only
    /// output). The honest-fail state machine (P0.5 `deepread.honest_fail`)
    /// requires the caller to mark the task `.failed` when `didFail` is true,
    /// instead of marking it `.succeeded` with empty sections.
    struct GenerationResult {
        let markdown: String
        let didFail: Bool
        let failureReason: String
        var structuredJSON: String? = nil
        /// Stage labels (e.g. "深度分析") that produced no usable content after
        /// the in-stage retry. Empty = every stage contributed. Non-empty runs are
        /// still completed honestly (Android's per-section FAILED analogue) but
        /// the caller MUST surface this instead of silently thinning the article.
        var missingSections: [String] = []
    }

    /// Terminal outcome of a deep-read run, decoupled from the caller's
    /// side-effects (navigation/banner). Both the create and retry view paths
    /// route their `GenerationResult` through `outcome(for:offlineFallback:)`,
    /// so the "didFail → .failed, else → completed draft" decision is a single
    /// unit-tested source of truth — a caller can no longer silently drop
    /// `didFail` and mark an all-failed run succeeded (closes the
    /// deepread.honest_fail caller-honoring gap on BOTH surfaces).
    enum DeepReadOutcome: Equatable {
        case completed(markdown: String, structuredJSON: String? = nil)
        case failed(reason: String)
    }

    /// Maps a `GenerationResult` to a terminal `DeepReadOutcome`. An honest
    /// failure (every stage threw/empty) becomes `.failed`; otherwise the run
    /// completes, substituting the deterministic offline draft only when the
    /// model produced empty markdown (never fabricating success).
    static func outcome(for result: GenerationResult, offlineFallback: String) -> DeepReadOutcome {
        if result.didFail {
            return .failed(reason: result.failureReason)
        }
        return .completed(
            markdown: result.markdown.isEmpty ? offlineFallback : result.markdown,
            structuredJSON: result.structuredJSON
        )
    }

    /// Same stage pipeline as `generateViaLLM`, but reports honest failure:
    /// `didFail` is true when every stage either threw or produced empty output.
    /// A run where at least one stage produced usable text is NOT a failure
    /// (partial output is still surfaced honestly as a completed draft).
    static func generateViaLLMResult(
        task: IOSDeepReadTask,
        providerSetting: ProviderSetting,
        model: Model,
        provider: IOSAgentTextProvider = OpenAIKmpProviderAdapter(),
        now: Date = Date(),
        onStageProgress: (@MainActor (_ label: String, _ index: Int, _ total: Int) -> Void)? = nil,
        initialOutput: IOSDeepReadOutput? = nil,
        targetStages: Set<String>? = nil,
        stageTimeouts: [String: Double]? = nil
    ) async -> GenerationResult {
        // Build a source block incl. any captured image URLs (so the model can obey
        // the "images only from sources" rule). Exclude failed-search sources.
        let usableSources = task.sources.filter(\.hasUsableGenerationContent)
        guard !usableSources.isEmpty else {
            return GenerationResult(
                markdown: "",
                didFail: true,
                failureReason: "没有可用来源"
            )
        }
        let usable = Array(usableSources.prefix(10))
#if DEBUG
        NSLog("[AmberDeepRead] sources=\(task.sources.count) usable=\(usable.count)")
#endif

        // Article plan first (Android generateArticlePlan parity): one call decides
        // the angle / narrative slots / analysis questions / stakeholders; any
        // failure falls back to the deterministic local plan. The plan drives the
        // per-stage source bucketing and the prompt injections.
        let plan = await synthesizePlan(
            topicTitle: task.title,
            usableSources: usable,
            providerSetting: providerSetting,
            model: model,
            provider: provider,
            timeoutSeconds: stageTimeouts?["结构规划"] ?? planTimeoutSeconds
        )
        await onStageProgress?("结构规划", 0, 4)
#if DEBUG
        NSLog("[AmberDeepRead] plan angle=\(plan.overviewAngle.prefix(60)) stakeholders=\(plan.stakeholders.count) requiredIds=\(plan.requiredSourceIds)")
#endif

        // 4 JSON stages merged into one IOSDeepReadOutput (Android DeepReadAgentRunManager parity):
        // overview -> narrative -> analysis -> extended-reading. Each stage outputs ONLY its
        // new fields (the accumulator merges prior stages) — re-emitting the whole merged
        // JSON is exactly what blows past maxTokens mid-stage and yields truncated,
        // unparseable output, which is the "only the overview survived" failure mode.
        // A stage that throws / returns unparseable JSON / omits its own fields gets ONE
        // retry with a corrective note before being dropped; dropped stages are reported
        // in `missingSections` instead of silently thinning the article.
        // sourceLimit/excerptLimit/timeout mirror Android (6/1000/90s, 9/1400/110s,
        // 8/1400/150s, 12/700/90s).
        let stages: [(label: String, instruction: String, schema: String, retryNote: String, fieldsPresent: (IOSDeepReadOutput) -> Bool, sourceLimit: Int, excerptLimit: Int, timeoutSeconds: Double)] = [
            ("概览",
             "只完成 topic_type、summary、key_entities。summary 像杂志导语，约 120-250 字、完整句子优先、说明为什么值得读，按 Article Plan 的 angle 组织。key_entities 只列 3-8 个最核心的人物、机构或地点，每个不超过 12 字。本阶段不要输出 timeline / core_points / analysis / extended_reading。不要编造来源之外的事实。",
             #"{"topic_type":"event|opinion|product|person","summary":"约120-250字中文杂志导语","key_entities":["关键实体"]}"#,
             "上一次输出没有包含 summary 字段或太短。请直接输出包含 summary（约120-250字中文导语）的 JSON 对象。",
             { $0.summary.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.overviewSummaryMinChars },
             6, 1_000, 90),
            ("时间轴叙事",
             "在已有概览基础上补齐 timeline 和 core_points。timeline 用 4-7 条讲清「早期背景 → 直接导火索 → 当前事件 → 后续影响」，并覆盖 Article Plan 的 narrative_slots；date 只写日期或时间（如「2026年10月2日」「10月初」），不要写阶段名、括号说明或「背景」之类的标签；只收录与本话题直接相关的事件，仅作类比的历史素材不要放进时间轴；is_highlight 只标 1-3 个最关键的节点。core_points 给 3-5 条，是你消化来源后的中文关键脉络（不是来源清单），每条讲一个独立判断并解释为什么重要；不要复述时间轴，不要写关于来源或写作方法的说明。",
             #"{"timeline":[{"date":"日期或时间","event":"连贯叙事事件","is_highlight":true}],"core_points":[{"point":"关键脉络","supporting":"为什么重要"}]}"#,
             "上一次输出没有包含 timeline 或 core_points 字段。请基于来源给出至少一条 timeline 事件或一个 core_point 的 JSON 对象。",
             { !$0.timeline.isEmpty || !$0.corePoints.isEmpty },
             9, 1_400, 110),
            ("深度分析",
             "在已有概览和叙事基础上补齐 analysis。core_dispute 用 1-2 句回答各方到底在争什么，不要与关键脉络重复。perspectives 按 Article Plan 的 stakeholders 与 analysis_questions 展开，给出 3-5 个不同当事方/利益方的立场（如监管/政府、涉事企业、消费者/用户、竞争对手、专家/媒体），每条用 viewpoint+holder 表达，避免只有两个立场；holder 只写当事方名称，不超过 12 字，不要包含文章标题或出处。quotes 最多 3 条，必须是来源中具名人物或机构说过的原话，文章标题、报道摘要和网友评论都不算；attribution 写「姓名或机构，身份」，不超过 20 字；没有可靠原话就留空数组。implications 写对行业/公众/政策的短期和长期影响。uncertainties 列出 0-4 条仍未确认的说法（参考 Article Plan 的 risk_or_uncertainty）：只有单一来源、来源之间互相矛盾或尚待官方确认的事实，每条写清哪一点待确认、为什么，不超过 60 字；都已确认就留空数组。",
             #"{"analysis":{"core_dispute":"核心分歧，可为空","perspectives":[{"viewpoint":"观点","holder":"持有方"}],"implications":"影响分析，可为空","quotes":[{"text":"原话或关键表态","attribution":"出处"}]},"uncertainties":["待核实的说法及原因"]}"#,
             "上一次输出没有包含 analysis 字段。请输出包含 core_dispute、perspectives（至少 3 个立场）和 implications 的 analysis JSON 对象。",
             { $0.analysis.hasContent },
             8, 1_400, 150),
            ("扩展阅读",
             "做最后整理：补齐 extended_reading、references 与 hero_image_url。两者都只使用来源里的 title/url/source：references 列出本文实际依据的 4-8 条来源（优先 Article Plan 的 required_source_ids）；extended_reading 只放不在 references 里、能帮助延伸理解的背景或原始资料链接（0-5 条），没有就留空数组。与话题无关、仅作类比的来源不要放入任何一处。hero_image_url 只能从来源 images 列表中选择，没有可靠图片时留空字符串。可选：如果因果链/流程图能帮助理解，补充 diagram（3-6 个节点，type 取 causal_chain|process_flow|stakeholder_map|system_structure|comparison_matrix，节点 label 约 30 字内，edges 只保留关键关系），不需要就省略整个 diagram 字段。",
             #"{"extended_reading":[{"title":"中文标题","url":"URL","source":"来源"}],"references":[{"title":"中文标题","url":"URL","source":"来源"}],"hero_image_url":"只能用来源 images 中的 URL，可为空","hero_caption":"图片说明，可为空"}"#,
             "上一次输出没有包含 references 字段。请从来源中挑选 4-8 条真实 title/url 链接作为 references 输出 JSON 对象。",
             { !$0.references.isEmpty || !$0.extendedReading.isEmpty || ($0.heroImageUrl?.isEmpty == false) || ($0.diagram?.nodes.count ?? 0) >= 2 },
             12, 700, 90),
        ]

        var merged = initialOutput ?? IOSDeepReadOutput()
        var threwCount = 0
        var lastProviderError: String?
        var missingSections: [String] = []
        let stagesToRun = stages.filter { targetStages?.contains($0.label) ?? true }
        for (stageIndex, stage) in stagesToRun.enumerated() {
            let priorJSON = merged.hasStructuredBody ? (encodeStructured(merged) ?? "") : ""
            let stageSources = stageSourcesBlock(
                for: usable, stageLimit: stage.sourceLimit, excerptLimit: stage.excerptLimit, plan: plan
            )
            var stageError: String? = nil
            var parseFailed = false
            var stageSucceeded = false
            for attempt in 1...2 {
                var retryNote: String? = nil
                if attempt == 2 {
                    retryNote = stageError.map {
                        "上一次调用失败（\(String($0.prefix(160)))），请重新输出本阶段 JSON。"
                    } ?? (parseFailed
                        ? "上一次输出无法解析为合法 JSON。请直接输出本阶段字段的 JSON 对象，不要任何解释或 Markdown。"
                        : stage.retryNote)
                }
                let prompt = buildStagePrompt(
                    topicTitle: task.title, stageLabel: stage.label, instruction: stage.instruction,
                    schema: stage.schema, priorJSON: priorJSON, sourcesBlock: stageSources,
                    plan: plan, retryNote: retryNote
                )
                let (text, error) = await synthesizeJSON(
                    prompt: prompt, providerSetting: providerSetting, model: model, provider: provider,
                    timeoutSeconds: stageTimeouts?[stage.label] ?? stage.timeoutSeconds
                )
                stageError = error
                parseFailed = false
                if let error {
                    threwCount += 1
                    lastProviderError = error
#if DEBUG
                    NSLog("[AmberDeepRead] stage=\(stage.label) attempt=\(attempt) threw: \(error.prefix(300))")
#endif
                    continue
                }
                var parsedOutput: IOSDeepReadOutput? = nil
                var repairedTruncation = false
                if let parsed = parseStageJSON(text), parsed.hasStructuredBody {
                    parsedOutput = parsed
                } else if let repaired = repairTruncatedJSON(text),
                          let parsed = parseStageJSON(repaired),
                          parsed.hasStructuredBody {
                    // The repaired JSON parsed: a later failure is a missing-fields
                    // problem, not a parse problem.
                    parsedOutput = parsed
                    repairedTruncation = true
                }
                if let parsed = parsedOutput {
                    // Gate before merge (Android writer-tool semantics): content that
                    // does not meet the stage minimums is not folded into the article.
                    if stage.fieldsPresent(parsed) {
                        merged = merged.merged(with: parsed)
                        stageSucceeded = true
#if DEBUG
                        if repairedTruncation {
                            NSLog("[AmberDeepRead] stage=\(stage.label) attempt=\(attempt) repaired truncated JSON")
                        }
#endif
                        break
                    }
                    parseFailed = false
#if DEBUG
                    NSLog("[AmberDeepRead] stage=\(stage.label) attempt=\(attempt) missing stage fields; chars=\(text.count) head=\(text.prefix(120))")
#endif
                } else {
                    parseFailed = true
#if DEBUG
                    NSLog("[AmberDeepRead] stage=\(stage.label) attempt=\(attempt) unparseable; chars=\(text.count) head=\(text.prefix(120))")
#endif
                }
            }
            if !stageSucceeded {
                missingSections.append(stage.label)
            }
            await onStageProgress?(stage.label, stageIndex + 1, stagesToRun.count)
        }
#if DEBUG
        if !missingSections.isEmpty {
            NSLog("[AmberDeepRead] missing sections after retries: \(missingSections.joined(separator: "、"))")
        }
#endif

        let date = IOSDeepReadDateFormatters.detail.string(from: now)
        // Honest failure only when nothing usable came back at all.
        let didFail = !merged.hasStructuredBody
        let reason: String
        if didFail && threwCount == stagesToRun.count * 2 {
            reason = lastProviderError.map(providerFailureReason)
                ?? "模型调用全部失败，请检查网络、API Key 或模型配置后重试。"
        } else if didFail {
            reason = "未能生成可用的深度阅读内容，请换个来源或模型后重试。"
        } else {
            reason = ""
        }

        let structuredJSON = merged.hasStructuredBody ? encodeStructured(merged) : nil
        let body = merged.hasStructuredBody
            ? markdownFromStructured(merged, title: task.title, date: date)
            : "# \(task.title)\n\n\(date)\n"
        return GenerationResult(
            markdown: body,
            didFail: didFail,
            failureReason: reason,
            structuredJSON: structuredJSON,
            missingSections: missingSections
        )
    }

    /// 已归类的报错（鉴权、超时、限流等）用友好文案；未归类的保留服务商原话片段，
    /// 否则只剩「操作失败」，用户无从判断是参数被拒还是模型不可用。
    static func providerFailureReason(_ raw: String) -> String {
        let friendly = IOSDeepReadUserFacingText.sanitize(raw)
        let generic = IOSAppLocalization.string("操作失败，请稍后重试。", defaultValue: "操作失败，请稍后重试。")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard friendly == generic, !trimmed.isEmpty else { return friendly }
        // 外层横幅已是「深度阅读生成失败：」，这里只标来源；保留中文前缀，二次清洗靠它判定可原样展示。
        let limit = 200
        let snippet = trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
        return "服务商返回：" + snippet
    }

    // MARK: - Stage JSON helpers

    private static func buildStagePrompt(topicTitle: String, stageLabel: String, instruction: String, schema: String, priorJSON: String, sourcesBlock: String, plan: IOSDeepReadArticlePlan? = nil, retryNote: String? = nil) -> String {
        var b = "你是 AmberAgent 的深度阅读编辑，分阶段生成高端 News 杂志风格的结构化深读稿。\n"
        b += "话题：\(topicTitle)\n当前阶段：\(stageLabel)\n\n"
        b += "## 阶段要求\n- \(instruction)\n"
        b += "- 输出合法 JSON 对象，不要代码围栏、不要前后解释。\n"
        b += "- 只输出本阶段新增字段；上一阶段字段不要重复输出，系统会自动合并。\n"
        b += "- 用户可见文本必须是简体中文；url 原样保留。\n"
        b += "- 不要输出 null；没有内容时用空字符串或空数组。\n\n"
        if let plan {
            b += "## Article Plan（本地规划，只读）\n"
            if !plan.overviewAngle.isEmpty { b += "- angle: \(plan.overviewAngle)\n" }
            if !plan.narrativeSlots.isEmpty { b += "- narrative_slots: \(plan.narrativeSlots.joined(separator: " / "))\n" }
            if !plan.analysisQuestions.isEmpty {
                b += "- analysis_questions:\n"
                plan.analysisQuestions.forEach { question in b += "  - \(question)\n" }
            }
            if !plan.stakeholders.isEmpty { b += "- stakeholders: \(plan.stakeholders.joined(separator: " / "))\n" }
            if !plan.riskOrUncertainty.isEmpty {
                b += "- risk_or_uncertainty:\n"
                plan.riskOrUncertainty.forEach { risk in b += "  - \(risk)\n" }
            }
            if !plan.requiredSourceIds.isEmpty { b += "- required_source_ids: \(plan.requiredSourceIds.map(String.init).joined(separator: ", "))\n" }
            b += "\n"
        }
        if !priorJSON.isEmpty {
            b += "## 上一阶段 JSON（已生成内容，仅供参考，不要重复输出）\n\(priorJSON.deepReadPrefixString(4000))\n\n"
        }
        b += "## 本阶段 JSON 字段\n\(schema)\n\n"
        if let retryNote {
            b += "## 重试要求（上一次未通过）\n- \(retryNote)\n\n"
        }
        b += "## 来源\n\(sourcesBlock)\n"
        return b
    }

    /// One JSON-only model call with the deep-read timeout and error mapping; also used by close reading.
    static func synthesizeJSON(prompt: String, providerSetting: ProviderSetting, model: Model, provider: IOSAgentTextProvider, timeoutSeconds: Double = 150) async -> (text: String, error: String?) {
        let system = "你是 AmberAgent 的深度阅读结构化写作助手。只基于提供的来源写作，不编造，只输出合法 JSON 对象。"
        let messages = [
            UIMessage.companion.system(prompt: system),
            UIMessage.companion.user(prompt: prompt)
        ]
        // 不固定温度：GPT-5 系列、Kimi 等只接受默认温度，传 0.3 会被 400 拒绝；与聊天一致交给服务商默认。
        let params = TextGenerationParams(
            model: model,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .off,
            customHeaders: IOSDeepReadSynthesisRunner.requestHeaders(for: providerSetting, model: model.customHeaders),
            customBody: model.customBodies
        )
        let request = DeepReadSynthesisRequest(
            providerSetting: providerSetting,
            messages: messages,
            params: params,
            provider: provider
        )
        do {
            let result = try await withTimeout(seconds: timeoutSeconds) {
                await IOSDeepReadSynthesisRunner.run(
                    provider: request.provider,
                    providerSetting: request.providerSetting,
                    messages: request.messages,
                    params: request.params
                )
            }
            if let failure = result.providerFailureMessage, !result.hitOutputLimit {
                return ("", failure)
            }
            if result.hitStepLimit || result.pendingApproval != nil {
                return ("", "深度阅读生成未在单轮内完成。")
            }
            let text = (result.messages.last(where: { $0.role == MessageRole.assistant })?.parts ?? [])
                .compactMap { $0 as? UIMessagePart.Text }
                .map { $0.text }
                .joined(separator: "")
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        } catch {
            // Swift-native LocalizedError structs do not surface errorDescription
            // through the NSError-bridged `localizedDescription`; read it first so
            // the stage retry note can name the real reason (e.g. 超时).
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ("", message)
        }
    }

    // MARK: - Planning (Android generateArticlePlan parity)

    private static let overviewSummaryMinChars = 24
    private static let planTimeoutSeconds: Double = 120

    private static func synthesizePlan(
        topicTitle: String,
        usableSources: [IOSDeepReadSource],
        providerSetting: ProviderSetting,
        model: Model,
        provider: IOSAgentTextProvider,
        timeoutSeconds: Double
    ) async -> IOSDeepReadArticlePlan {
        let fallback = fallbackPlan(topicTitle: topicTitle, usableSources: usableSources)
        let prompt = buildPlanningPrompt(topicTitle: topicTitle, usableSources: usableSources)
        let (text, error) = await synthesizeJSON(
            prompt: prompt, providerSetting: providerSetting, model: model,
            provider: provider, timeoutSeconds: timeoutSeconds
        )
        if error != nil {
#if DEBUG
            NSLog("[AmberDeepRead] plan fell back to local plan: \(error?.prefix(200) ?? "")")
#endif
            return fallback
        }
        guard let raw = extractJSONObject(text),
              let parsed = try? JSONDecoder().decode(IOSDeepReadArticlePlan.self, from: Data(raw.utf8)) else {
#if DEBUG
            NSLog("[AmberDeepRead] plan unparseable, fell back to local plan; chars=\(text.count) head=\(text.prefix(120))")
#endif
            return fallback
        }
        return parsed.normalized(with: fallback, sourceCount: usableSources.count)
    }

    /// Deterministic local plan used when the planning call fails — mirrors
    /// Android's `DeepReadResearchHarness.fallbackPlan` wording.
    private static func fallbackPlan(topicTitle: String, usableSources: [IOSDeepReadSource]) -> IOSDeepReadArticlePlan {
        var plan = IOSDeepReadArticlePlan()
        plan.overviewAngle = "从已核查来源解释「\(topicTitle)」发生了什么、为什么值得读，以及哪些结论仍需保守表达。"
        plan.narrativeSlots = [
            "背景和直接触发因素",
            "关键进展或时间线",
            "当前状态与后续观察点",
        ]
        plan.analysisQuestions = [
            "核心矛盾是什么，各方到底在争什么？",
            "这件事会影响哪些用户、公司、行业或公共议题？",
            "有哪些反方证据、不确定点或互相矛盾的说法需要降格表达？",
        ]
        plan.riskOrUncertainty = [
            "来源之间未互相印证的事实不得写成定论。",
            "没有来源支撑的价格、时间、人物表态、因果关系需要跳过或标注为不确定。",
        ]
        plan.requiredSourceIds = Array(1...usableSources.count)
        return plan
    }

    private static func buildPlanningPrompt(topicTitle: String, usableSources: [IOSDeepReadSource]) -> String {
        var b = "你是 AmberAgent 深度阅读的结构规划器。\n"
        b += "只输出合法 JSON，不要 Markdown、不要代码围栏、不要解释。\n"
        b += "话题：\(topicTitle)\n\n"
        b += "## 可用来源（编号是 required_source_ids 的取值）\n"
        for (index, source) in usableSources.enumerated() {
            let excerpt = IOSDeepReadSourceNormalizer.cleanMultiline(source.content).deepReadPrefixString(300)
            b += "- [\(index + 1)] \(source.kind.title)｜\(source.title)\n"
            if let url = source.url, !url.isEmpty { b += "  url: \(url)\n" }
            b += "  excerpt: \(excerpt)\n"
        }
        b += "\n## 输出 JSON Schema\n"
        b += #"{"overview_angle":"一两句话说明文章角度","narrative_slots":["必须覆盖的叙事槽位"],"analysis_questions":["必须回答的分析问题"],"stakeholders":["相关方"],"risk_or_uncertainty":["风险、不确定点或反方证据"],"required_source_ids":[1,2]}"#
        b += "\n\n要求：\n"
        b += "- required_source_ids 用上面的编号，尽量覆盖所有可用来源。\n"
        b += "- analysis_questions 必须覆盖核心矛盾、影响链条、反方证据或不确定点。\n"
        b += "- 不要创造不存在的来源编号。\n"
        return b
    }

    /// Per-stage source bucketing (Android `cardsFor(stage:)` parity): the plan's
    /// required ids come first, then the remaining sources in original order,
    /// capped at the stage's source count and per-source excerpt limit.
    private static func stageSourcesBlock(
        for sources: [IOSDeepReadSource],
        stageLimit: Int,
        excerptLimit: Int,
        plan: IOSDeepReadArticlePlan
    ) -> String {
        let required = Set(plan.requiredSourceIds)
        let ordered = sources.enumerated()
            .map { (index: $0.offset + 1, source: $0.element) }
            .sorted { a, b in
                let aRequired = required.contains(a.index)
                let bRequired = required.contains(b.index)
                if aRequired != bRequired { return aRequired && !bRequired }
                return a.index < b.index
            }
        return ordered.prefix(stageLimit).map { entry in
            var lines = "[\(entry.index)] \(entry.source.kind.title)｜\(entry.source.title)"
            if let url = entry.source.url, !url.isEmpty { lines += "\n- url: \(url)" }
            if let image = entry.source.metadata["hero_image_url"], !image.isEmpty {
                lines += "\n- images: \(image)"
            }
            lines += "\n- excerpt: \(IOSDeepReadSourceNormalizer.cleanMultiline(entry.source.content).deepReadPrefixString(excerptLimit))"
            return lines
        }.joined(separator: "\n\n")
        .deepReadPrefixString(9_000)
    }

    // MARK: - Timeout (Android withTimeout parity)

    private struct DeepReadSynthesisRequest: @unchecked Sendable {
        let providerSetting: ProviderSetting
        let messages: [UIMessage]
        let params: TextGenerationParams
        let provider: IOSAgentTextProvider
    }

    private struct IOSDeepReadStageTimeoutError: Error, LocalizedError {
        let seconds: Int
        var errorDescription: String? { "阶段超时（\(seconds) 秒预算用尽）" }
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        // Result-based group so cancelled children can never throw at scope exit
        // and replace the winner's value.
        let outcome: Result<T, Error> = await withTaskGroup(of: Result<T, Error>.self) { group in
            group.addTask {
                do { return .success(try await body()) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                if Task.isCancelled { return .failure(CancellationError()) }
                return .failure(IOSDeepReadStageTimeoutError(seconds: Int(seconds.rounded())))
            }
            guard let first = await group.next() else {
                return .failure(IOSDeepReadStageTimeoutError(seconds: Int(seconds.rounded())))
            }
            group.cancelAll()
            return first
        }
        return try outcome.get()
    }

    static func parseStageJSON(_ text: String) -> IOSDeepReadOutput? {
        guard let json = extractJSONObject(text) else { return nil }
        return try? JSONDecoder().decode(IOSDeepReadOutput.self, from: Data(json.utf8))
    }

    /// Best-effort repair for JSON cut off by max-token truncation: balances
    /// unclosed braces/brackets, closes an unterminated string and strips a
    /// dangling comma before each closer it appends. Returns nil when the text
    /// is already balanced (nothing to repair) or contains no object at all.
    /// Repaired output can still fail to decode (e.g. a truncated key without a
    /// value) — the caller then falls back to the stage retry.
    static func repairTruncatedJSON(_ text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var index = start
        while index < chars.count {
            let c = chars[index]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                stack.append("}")
            } else if c == "}" {
                if stack.last == "}" { stack.removeLast() }
            } else if c == "[" {
                stack.append("]")
            } else if c == "]" {
                if stack.last == "]" { stack.removeLast() }
            }
            index += 1
        }
        guard inString || !stack.isEmpty else { return nil }
        var body = String(chars[start...])
        var suffix = ""
        if inString { suffix += "\"" }
        for closer in stack.reversed() {
            if let last = body.last, last == "," { body.removeLast() }
            suffix.append(closer)
        }
        return body + suffix
    }

    /// First balanced top-level {...} object (ignores braces inside strings), so a
    /// response wrapped in ```json fences or surrounding prose still parses.
    static func extractJSONObject(_ text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            }
            i += 1
        }
        return nil
    }

    static func encodeStructured(_ output: IOSDeepReadOutput) -> String? {
        guard let data = try? JSONEncoder().encode(output) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func markdownFromStructured(_ o: IOSDeepReadOutput, title: String, date: String) -> String {
        var b = "# \(title)\n\n\(date)\n"
        if !o.summary.isEmpty { b += "\n## 摘要\n\(o.summary)\n" }
        if !o.timeline.isEmpty {
            b += "\n## 时间轴\n"
            for e in o.timeline { b += "- **\(e.date)** \(e.event)\n" }
        }
        if !o.corePoints.isEmpty {
            b += "\n## 关键脉络\n"
            for p in o.corePoints { b += "- **\(p.point)**" + (p.supporting.map { "：\($0)" } ?? "") + "\n" }
        }
        if o.analysis.hasContent {
            b += "\n## 深度分析\n"
            if let d = o.analysis.coreDispute, !d.isEmpty { b += "> \(d)\n\n" }
            for p in o.analysis.perspectives where !p.viewpoint.isEmpty {
                b += "- **\(p.holder ?? "")**：\(p.viewpoint)\n"
            }
            for q in o.analysis.quotes where !q.text.isEmpty {
                b += "> “\(q.text)”"
                if let attribution = q.attribution, !attribution.isEmpty { b += " —— \(attribution)" }
                b += "\n\n"
            }
            if let imp = o.analysis.implications, !imp.isEmpty { b += "\n\(imp)\n" }
        }
        if !o.uncertainties.isEmpty {
            b += "\n## 待核实\n"
            for item in o.uncertainties { b += "- \(item)\n" }
        }
        if !o.extendedReading.isEmpty {
            b += "\n## 扩展阅读\n"
            for l in o.extendedReading { b += "- [\(l.title)](\(l.url))\n" }
        }
        if !o.references.isEmpty {
            b += "\n## 参考来源\n"
            for l in o.references { b += "- [\(l.title)](\(l.url))\n" }
        }
        return b
    }

    /// Retry-generation decision as a testable static seam: given the already-
    /// resolved (non-optional) provider — the caller resolves it on the MainActor
    /// via `resolveProviderSetting` and passes the unwrapped fresh value in,
    /// mirroring the create path's concurrency shape so it can cross the async
    /// boundary without a data race — runs the staged pipeline and maps the
    /// result to a terminal `DeepReadOutcome` (didFail → `.failed`, else a
    /// completed draft). The caller handles the no-provider/no-key offline
    /// fallback. The decision lives here so it is unit-tested end-to-end (closes
    /// the deepread retry-path dual leak: provider_real + honest_fail).
    static func retryOutcome(
        resolvedProvider: ProviderSetting,
        model: Model,
        task: IOSDeepReadTask,
        provider: IOSAgentTextProvider = OpenAIKmpProviderAdapter(),
        now: Date = Date()
    ) async -> DeepReadOutcome {
        let result = await generateViaLLMResult(
            task: task,
            providerSetting: resolvedProvider,
            model: model,
            provider: provider,
            now: now
        )
        return outcome(for: result, offlineFallback: generate(task: task, now: now))
    }

}
