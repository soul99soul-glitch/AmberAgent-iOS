import Foundation
@preconcurrency import Shared

@MainActor
extension IOSCouncilRoomRunner {
    /// Parses the host's strict-JSON seat plan `{"seats":[{"name","lens"}]}` into
    /// dynamic council speakers. Assigns the supplied supported models in order,
    /// without repeating until the pool is exhausted. Tolerates
    /// ```json fences / surrounding prose (reuses the deep-read balanced-brace
    /// extractor). Returns [] when fewer than 2 usable seats parse, so the caller
    /// keeps the resolved default seats as a fallback.
    static func plannedSeatsFromJSON(
        _ text: String,
        maxSeats: Int,
        routes: [IOSCouncilModelRouteDescriptor]
    ) -> [IOSCouncilRoomSpeaker] {
        let usableRoutes = routes.compactMap { route -> IOSCouncilModelRouteDescriptor? in
            guard let providerId = route.providerId.trimmedNilIfBlank,
                  let modelId = route.modelId.trimmedNilIfBlank else { return nil }
            return IOSCouncilModelRouteDescriptor(providerId: providerId, modelId: modelId)
        }
        guard !usableRoutes.isEmpty else { return [] }
        // 扫描所有顶层 JSON 对象，取第一个含 seats 数组的：主持人在真正 JSON 前用了带
        // 花括号的列举（如 {历史, 政治}）时，extractJSONObject 会先抓到干扰对象而静默回退，
        // 这里跳过它继续找含 seats 的对象。
        let seats: [[String: Any]]? = {
            for objectString in Self.topLevelJSONObjects(text) {
                guard let data = objectString.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let seats = obj["seats"] as? [[String: Any]] else { continue }
                return seats
            }
            return nil
        }()
        guard let seats else { return [] }
        var result: [IOSCouncilRoomSpeaker] = []
        var seenNames = Set<String>()
        for entry in seats {
            guard let rawName = entry["name"] as? String else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seenNames.insert(name.lowercased()).inserted else { continue }
            let lensRaw = (entry["lens"] as? String) ?? (entry["role"] as? String) ?? (entry["prompt"] as? String) ?? ""
            let lens = lensRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let route = usableRoutes[result.count % usableRoutes.count]
            result.append(IOSCouncilRoomSpeaker(
                id: "planned-\(Self.digest(name).prefix(8))",
                name: name,
                rolePrompt: lens.isEmpty ? "围绕议题提供独立、专业的视角。" : lens,
                modelId: route.modelId,
                providerId: route.providerId,
                reasoning: .medium,
                prompt: "",
                isHost: false
            ))
            if result.count >= maxSeats { break }
        }
        return result.count >= 2 ? result : []
    }

    /// 文本中所有顶层配平 `{...}` 对象的子串（忽略字符串内的花括号与转义），按出现顺序。
    /// 用于在主持人输出里跳过不含 seats 的干扰对象，定位真正的席位 JSON。
    private static func topLevelJSONObjects(_ text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            let start = i
            var depth = 0
            var inString = false
            var escaped = false
            var j = i
            var closed = false
            while j < chars.count {
                let c = chars[j]
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
                    if depth == 0 {
                        result.append(String(chars[start...j]))
                        i = j + 1
                        closed = true
                        break
                    }
                }
                j += 1
            }
            if !closed { break }
        }
        return result
    }

    /// Dynamic seats prefer one model from each non-host provider before reusing
    /// the host provider. The exact host route remains the last fallback.
    static func diverseSeatRoutes(
        routes: [IOSCouncilModelRouteDescriptor],
        hostRoute: IOSCouncilModelRouteDescriptor
    ) -> [IOSCouncilModelRouteDescriptor] {
        var seenRoutes = Set<String>()
        let normalized = routes.compactMap { route -> IOSCouncilModelRouteDescriptor? in
            guard let providerId = route.providerId.trimmedNilIfBlank,
                  let modelId = route.modelId.trimmedNilIfBlank else { return nil }
            let normalized = IOSCouncilModelRouteDescriptor(providerId: providerId, modelId: modelId)
            guard seenRoutes.insert(routeKey(normalized)).inserted else { return nil }
            return normalized
        }
        let hostKey = routeKey(hostRoute)
        let alternatives = normalized.filter { routeKey($0) != hostKey }

        func providerDiverse(_ candidates: [IOSCouncilModelRouteDescriptor]) -> [IOSCouncilModelRouteDescriptor] {
            var seenProviders = Set<String>()
            var firstPerProvider: [IOSCouncilModelRouteDescriptor] = []
            var remaining: [IOSCouncilModelRouteDescriptor] = []
            for route in candidates {
                if seenProviders.insert(route.providerId).inserted {
                    firstPerProvider.append(route)
                } else {
                    remaining.append(route)
                }
            }
            return firstPerProvider + remaining
        }

        var result = providerDiverse(alternatives.filter { $0.providerId != hostRoute.providerId })
        result += providerDiverse(alternatives.filter { $0.providerId == hostRoute.providerId })
        if !hostRoute.providerId.isEmpty,
           !hostRoute.modelId.isEmpty,
           !result.contains(where: { routeKey($0) == hostKey }) {
            result.append(hostRoute)
        }
        return result
    }

    func hostSystemPrompt(settings: IOSCouncilRoomSettings) -> String {
        """
        \(settings.host.prompt)

        你在 iOS 模型议会 Room 中发言。保持中文、具体、可执行。只依据本轮实际执行结果描述过程，不要虚构模型、服务商或工具调用。
        """
    }

    func finalTopicPrompt(
        objective: String,
        research: IOSCouncilResearchBundle,
        sourceMaterials: String? = nil,
        limits: IOSCouncilRoomLimits,
        defaultSeats: [IOSCouncilRoomSpeaker]
    ) -> String {
        let materialsBlock = sourceMaterials?.trimmingCharacters(in: .whitespacesAndNewlines)
        let materialsSection: String
        if let materialsBlock, !materialsBlock.isEmpty {
            materialsSection = """

            用户上传材料（文件解析 / 图片视觉识别结果）：
            \(materialsBlock)
            """
        } else {
            materialsSection = ""
        }
        return """
        用户议题：
        \(objective)
        \(materialsSection)
        联网调研要点：
        \(research.summaryText.trimmedOr("本轮没有联网调研材料。"))

        请基于以上议题、上传材料（如有）与联网调研完善议题，补充关键背景和最新信息，形成一个清晰、有讨论价值的「最终议题」。
        若用户上传了材料，最终议题必须紧扣材料中的事实与争议点，不要忽略附件内容。
        直接输出完善后的议题正文即可，不要列席位、不要输出 JSON。
        """
    }

    func seatPlanSystemPrompt() -> String {
        """
        你是 iOS 模型议会的主持人，负责根据具体议题和联网调研，动态组建本轮最有价值的议员席位。
        只输出严格 JSON，不要代码围栏、不要任何解释文字。
        """
    }

    func seatPlanPrompt(
        objective: String,
        finalTopic: String,
        research: IOSCouncilResearchBundle,
        limits: IOSCouncilRoomLimits,
        sourceMaterials: String? = nil
    ) -> String {
        let materialsHint: String
        if let materials = sourceMaterials?.trimmingCharacters(in: .whitespacesAndNewlines),
           !materials.isEmpty {
            materialsHint = "用户已上传材料（文件/图片），席位应覆盖材料中的事实核验、影响面与决策维度。"
        } else {
            materialsHint = ""
        }
        return """
        最终议题：
        \(finalTopic.trimmedOr(objective))

        联网调研要点：
        \(research.summaryText.trimmedOr("（无联网调研材料，请基于议题本身判断）"))
        \(materialsHint.isEmpty ? "" : "\n\(materialsHint)\n")
        请针对这个【具体议题】动态设计 2 到 \(limits.maxSeats) 位最有价值的议员席位：
        - 紧扣本议题的真实关键维度，不要套用「工程/产品/风险」之类的通用模板，除非它们确实最贴切。
        - 每位议员视角独特、互补，合起来能覆盖议题的核心分歧与决策要点。
        - 议员简称 2-6 个字；职责用一句话写清它从什么角度、审视什么。

        只输出严格 JSON（不要代码围栏、不要解释）：
        {"seats":[{"name":"议员简称","lens":"该议员的具体职责与审视角度"}]}
        """
    }

    /// 清洗席位输出里模型幻觉出的伪联网搜索 / 工具调用文本。典型如 grok 在无可用工具时
    /// 把搜索冲动写成 `web_search / query … / num_results …`，并常被其包进误标的 ```html
    /// 围栏。终态与流式累积文本各调用一次；纯函数，便于单测。
    static func sanitizeSeatOutput(_ text: String) -> String {
        // 逐行状态机：围栏内整块缓冲，闭合时若含伪搜索则整块丢弃（含围栏标记），否则原样
        // 保留——正常代码块因此不受影响；围栏外逐行删裸的 web_search/query/num_results 行。
        // 刻意不用正则做条件删除，避开 NSRegularExpression 闭包重载与 NSRange 转换的坑。
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var fenceBuffer: [String] = []
        var inFence = false
        // 围栏外裸行删除的上下文态：query / num_results 只有在「前序出现过裸 web_search 行」
        // 的连续伪搜索块内才删，避免误删英文正常发言里行首恰为 query 的合法句子。
        // 遇到非空普通行即复位（说明已脱离伪搜索块）；空行不复位。
        var sawBareWebSearch = false

        func isPseudoSearch(_ s: String) -> Bool {
            let lower = s.lowercased()
            return lower.contains("web_search") || lower.contains("num_results")
        }
        func flushFence() {
            if !isPseudoSearch(fenceBuffer.joined(separator: "\n")) {
                out.append(contentsOf: fenceBuffer)
            }
            fenceBuffer.removeAll()
        }

        for line in lines {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if marker.hasPrefix("```") {
                fenceBuffer.append(line)
                if inFence {
                    flushFence()
                    inFence = false
                } else {
                    inFence = true
                }
                continue
            }
            if inFence {
                fenceBuffer.append(line)
                continue
            }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isWebSearchLine = t == "web_search" || t.hasPrefix("web_search ")
            let isQueryLine = t == "query" || t.hasPrefix("query ")
            let isNumResultsLine = t.hasPrefix("num_results")
            if isWebSearchLine {
                // web_search 是伪搜索块的锚点：删它并打开上下文，使紧随的 query/num_results
                // 行也被识别为同一伪搜索块而删除。
                sawBareWebSearch = true
                continue
            }
            if (isQueryLine || isNumResultsLine) && sawBareWebSearch {
                // 仅当处于伪搜索块上下文内才删 query/num_results 行；否则视为正常发言保留。
                continue
            }
            // 保留该行；非空普通行说明已脱离伪搜索块，复位上下文。
            if !t.isEmpty { sawBareWebSearch = false }
            out.append(line)
        }
        // 未闭合围栏（流式中围栏还没写完）：含伪搜索则暂不显示，否则保留。
        if inFence, !isPseudoSearch(fenceBuffer.joined(separator: "\n")) {
            out.append(contentsOf: fenceBuffer)
        }

        var result = out.joined(separator: "\n")
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private extension String {
    func trimmedOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    var trimmedNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

