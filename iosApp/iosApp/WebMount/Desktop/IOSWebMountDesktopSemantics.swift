import Foundation
import Observation
import WebKit


struct IOSWebMountDesktopSemanticElement: Equatable {
    let refs: Set<String>
    let selectors: Set<String>
    let role: String?
    let name: String?
    let inputType: String?
    let tag: String?
    let visible: Bool?
    let focused: Bool?
    let actionable: Bool?
    let disabled: Bool?

    func matchesReference(_ target: String) -> Bool {
        refs.contains(target)
    }

    func matchesSelector(_ target: String) -> Bool {
        selectors.contains(target)
    }

    func hasSameIdentity(as other: Self) -> Bool {
        [role, name, inputType, tag].map(Self.normalizedIdentityPart)
            == [other.role, other.name, other.inputType, other.tag].map(Self.normalizedIdentityPart)
    }

    private static func normalizedIdentityPart(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfBlank
    }

    var contractDictionary: [String: Any] {
        var value: [String: Any] = [:]
        if let ref = refs.sorted().first { value["ref"] = ref }
        if let selector = selectors.sorted().first { value["selector"] = selector }
        if let role { value["role"] = role }
        if let name { value["name"] = name }
        if let inputType { value["input_type"] = inputType }
        if let tag { value["tag"] = tag }
        if let visible { value["visible"] = visible }
        if let focused { value["focused"] = focused }
        if let actionable { value["actionable"] = actionable }
        if let disabled { value["disabled"] = disabled }
        return value
    }
}

struct IOSWebMountDesktopPageIdentity: Equatable {
    let documentID: String?
    let currentURL: String?

    func matches(_ other: Self) -> Bool {
        if documentID != nil || other.documentID != nil {
            return documentID != nil && documentID == other.documentID
        }
        return currentURL != nil && currentURL == other.currentURL
    }
}

enum IOSWebMountDesktopActionDisposition {
    case safe
    case approval(reason: String, label: String)
    case human(reason: String, label: String)
}

enum IOSWebMountDesktopSemantics {
    static func semanticElement(
        matching target: String,
        arguments: [String: Any],
        elements: [IOSWebMountDesktopSemanticElement]
    ) -> IOSWebMountDesktopSemanticElement? {
        if IOSWebMountDesktopMappingPolicy.string(arguments, "target") == nil, IOSWebMountDesktopMappingPolicy.string(arguments, "selector") != nil {
            return elements.first(where: { $0.matchesSelector(target) })
        }
        return elements.first(where: { $0.matchesReference(target) })
    }

    static func requireSafeTarget(
        _ arguments: [String: Any],
        toolName: String,
        elements: [IOSWebMountDesktopSemanticElement]
    ) throws -> String {
        let target = try IOSWebMountDesktopMappingPolicy.semanticTarget(arguments, toolName: toolName)
        guard !Self.isSensitiveTarget(target),
              let element = semanticElement(
                  matching: target,
                  arguments: arguments,
                  elements: elements
              ),
              Self.isSafe(element, for: toolName) else {
            throw IOSWebMountDesktopBackendError.sensitiveFieldRequiresHuman
        }
        return target
    }

    static func actionDisposition(
        element: IOSWebMountDesktopSemanticElement,
        toolName: String,
        arguments: [String: Any]
    ) -> IOSWebMountDesktopActionDisposition {
        let label = element.name?.nilIfBlank ?? element.role?.nilIfBlank ?? "page element"
        guard element.visible == true else {
            return .human(reason: "target_visibility_unconfirmed", label: label)
        }
        guard element.disabled != true, element.actionable != false else {
            return .human(reason: "target_not_actionable", label: label)
        }
        guard hasSufficientSemantics(element) else {
            return .human(reason: "target_semantics_unconfirmed", label: label)
        }
        let requestedTarget = [arguments["target"] as? String, arguments["selector"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
            .joined(separator: " ")
        let identity = [element.role, element.name, element.inputType, element.tag]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ") + " " + requestedTarget.lowercased()
        if isSensitiveElement(element)
            || isSensitiveTarget(requestedTarget)
            || identity.range(
                of: #"captcha|two.?factor|2fa|mfa|otp|one.?time|verification.?code|passkey|oauth|sign.?in|log.?in|登录|验证码|人机验证"#,
                options: .regularExpression
            ) != nil {
            return .human(reason: "login_or_sensitive_field", label: label)
        }
        if toolName == "wm_keys",
           (arguments["key"] as? String ?? arguments["text"] as? String ?? "")
            .caseInsensitiveCompare("Enter") == .orderedSame {
            return .approval(reason: "enter_may_submit", label: "Enter")
        }
        if toolName == "wm_type", arguments["submit"] as? Bool == true {
            return .approval(reason: "type_and_submit", label: label)
        }
        let highConsequencePattern = #"(?i)\b(pay|payment|purchase|buy|checkout|place.?order|submit|authorize|approve|confirm|send|publish|delete|remove)\b|支付|付款|购买|下单|提交|授权|确认|发送|发布|删除"#
        if identity.range(of: highConsequencePattern, options: .regularExpression) != nil {
            return .approval(reason: "high_consequence_action", label: label)
        }
        if toolName == "wm_select",
           identity.range(
               of: #"payment|billing|checkout|order|支付|账单|订单"#,
               options: [.regularExpression, .caseInsensitive]
           ) != nil {
            return .approval(reason: "payment_or_billing_selection", label: label)
        }
        return .safe
    }

    private static func hasSufficientSemantics(_ element: IOSWebMountDesktopSemanticElement) -> Bool {
        let role = element.role?.nilIfBlank
        let name = element.name?.nilIfBlank
        let inputType = element.inputType?.nilIfBlank
        let tag = element.tag?.nilIfBlank
        return role != nil && name != nil && (inputType != nil || tag != nil)
    }

    static func isVisibleAndSafe(
        _ element: IOSWebMountDesktopSemanticElement,
        kind: String
    ) -> Bool {
        guard element.visible == true,
              element.disabled != true,
              hasSufficientSemantics(element),
              !isSensitiveElement(element) else {
            return false
        }
        guard kind == "value" else { return true }
        let role = element.role?.lowercased() ?? ""
        let tag = element.tag?.lowercased() ?? ""
        return ["textbox", "searchbox", "combobox", "listbox"].contains(role)
            || ["input", "textarea", "select"].contains(tag)
    }

    static func isSensitiveTarget(_ target: String) -> Bool {
        let value = target.lowercased()
        return [
            "password", "passwd", "passcode", "otp", "one-time", "mfa", "2fa",
            "captcha", "card", "pan", "cvv", "cvc", "payment", "billing"
        ].contains { value.contains($0) }
    }

    private static func isSensitiveElement(_ element: IOSWebMountDesktopSemanticElement) -> Bool {
        let inputType = element.inputType?.lowercased() ?? ""
        if [
            "password", "hidden", "one-time-code", "otp", "cc-number", "cc-csc",
            "credit-card", "new-password", "current-password"
        ].contains(inputType) {
            return true
        }
        let identity = [element.role, element.name, element.inputType, element.tag]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return isSensitiveTarget(identity)
    }

    private static func isSafe(
        _ element: IOSWebMountDesktopSemanticElement,
        for toolName: String
    ) -> Bool {
        guard element.visible == true,
              element.disabled != true,
              element.actionable != false,
              !isSensitiveElement(element) else { return false }
        let role = element.role?.lowercased() ?? ""
        let tag = element.tag?.lowercased() ?? ""
        let inputType = element.inputType?.lowercased() ?? "text"
        let safeInputTypes = Set([
            "text", "email", "search", "tel", "url", "number", "date", "datetime-local",
            "month", "week", "time"
        ])
        switch toolName {
        case "wm_type":
            if ["textbox", "searchbox"].contains(role) { return true }
            return ["input", "textarea"].contains(tag) && safeInputTypes.contains(inputType)
        case "wm_select":
            return ["combobox", "listbox"].contains(role) || tag == "select" || inputType == "select"
        default:
            return false
        }
    }

    static func semanticElements(
        from text: String,
        backend: IOSWebMountBackendKind,
        remoteToolName: String
    ) -> [IOSWebMountDesktopSemanticElement] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            guard backend == .playwright_mcp else { return [] }
            return playwrightSemanticElements(from: text, remoteToolName: remoteToolName)
        }
        var elements: [IOSWebMountDesktopSemanticElement] = []

        func stringValue(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }

        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let refs = Set([
                    stringValue(dictionary["ref"]),
                    stringValue(dictionary["target_ref"]),
                    stringValue(dictionary["target"]),
                    stringValue(dictionary["id"])
                ].compactMap { $0 })
                let selectors = Set([
                    stringValue(dictionary["selector"]),
                    stringValue(dictionary["css_selector"])
                ].compactMap { $0 })
                let role = stringValue(dictionary["role"])
                    ?? stringValue(dictionary["aria_role"])
                let name = stringValue(dictionary["name"])
                    ?? stringValue(dictionary["accessible_name"])
                    ?? stringValue(dictionary["label"])
                    ?? stringValue(dictionary["text"])
                let inputType = stringValue(dictionary["input_type"])
                    ?? stringValue(dictionary["inputType"])
                    ?? stringValue(dictionary["type"])
                let tag = stringValue(dictionary["tag"])
                    ?? stringValue(dictionary["tag_name"])
                    ?? stringValue(dictionary["tagName"])
                let visible = (dictionary["visible"] as? NSNumber)?.boolValue
                    ?? (dictionary["is_visible"] as? NSNumber)?.boolValue
                let focused = (dictionary["focused"] as? NSNumber)?.boolValue
                    ?? (dictionary["is_focused"] as? NSNumber)?.boolValue
                let actionable = (dictionary["actionable"] as? NSNumber)?.boolValue
                    ?? (dictionary["is_actionable"] as? NSNumber)?.boolValue
                let disabled = (dictionary["disabled"] as? NSNumber)?.boolValue
                    ?? (dictionary["aria_disabled"] as? NSNumber)?.boolValue
                if !refs.isEmpty || !selectors.isEmpty {
                    let element = IOSWebMountDesktopSemanticElement(
                        refs: refs,
                        selectors: selectors,
                        role: role,
                        name: name,
                        inputType: inputType,
                        tag: tag,
                        visible: visible,
                        focused: focused,
                        actionable: actionable,
                        disabled: disabled
                    )
                    let isDuplicate = elements.contains {
                        !$0.refs.isDisjoint(with: element.refs)
                            || !$0.selectors.isDisjoint(with: element.selectors)
                    }
                    if !isDuplicate { elements.append(element) }
                }
                for child in dictionary.values { visit(child) }
            } else if let array = value as? [Any] {
                for child in array { visit(child) }
            }
        }

        visit(root)
        return elements.sorted { lhs, rhs in
            let lhsComplete = hasSufficientSemantics(lhs)
            let rhsComplete = hasSufficientSemantics(rhs)
            if lhsComplete != rhsComplete { return lhsComplete }
            let lhsKey = lhs.refs.sorted().first ?? lhs.selectors.sorted().first ?? ""
            let rhsKey = rhs.refs.sorted().first ?? rhs.selectors.sorted().first ?? ""
            return lhsKey < rhsKey
        }
    }

    private static func playwrightSemanticElements(
        from text: String,
        remoteToolName: String
    ) -> [IOSWebMountDesktopSemanticElement] {
        let lines: [Substring]
        if let snapshot = playwrightSnapshotBody(from: text) {
            lines = snapshot.split(separator: "\n", omittingEmptySubsequences: false)
        } else if remoteToolName == "browser_find" {
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        } else {
            return []
        }
        let pattern = #"^\s*-\s+([A-Za-z][A-Za-z0-9_-]*)(?:\s+\"((?:[^\"\\]|\\.)*)\")?.*\[ref=([^\]\s]+)\].*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var elements: [IOSWebMountDesktopSemanticElement] = []
        for lineSlice in lines {
            let line = String(lineSlice)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let roleRange = Range(match.range(at: 1), in: line),
                  let refRange = Range(match.range(at: 3), in: line) else {
                continue
            }
            let role = String(line[roleRange]).lowercased()
            let ref = String(line[refRange])
            let name: String?
            if let range = Range(match.range(at: 2), in: line) {
                name = String(line[range])
                    .replacingOccurrences(of: #"\""#, with: "\"")
                    .replacingOccurrences(of: #"\\"#, with: "\\")
                    .nilIfBlank
            } else {
                name = nil
            }
            let roleMetadata = playwrightRoleMetadata(role)
            let disabled = line.range(
                of: #"\[disabled(?:=true)?\]"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let element = IOSWebMountDesktopSemanticElement(
                refs: [ref],
                selectors: [],
                role: role,
                name: name,
                inputType: roleMetadata.inputType,
                tag: roleMetadata.tag,
                // Playwright's accessibility snapshot excludes aria-hidden and
                // display-hidden nodes; parsed entries are therefore visible in
                // the semantic tree. Structured gateways must still send an
                // explicit visible=true flag.
                visible: true,
                focused: line.range(
                    of: #"\[focused(?:=true)?\]"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil,
                actionable: !disabled,
                disabled: disabled
            )
            if !elements.contains(where: { $0.refs.contains(ref) }) {
                elements.append(element)
            }
        }
        return elements
    }

    private static func playwrightRoleMetadata(
        _ role: String
    ) -> (tag: String?, inputType: String?) {
        switch role {
        case "button": ("button", nil)
        case "link": ("a", nil)
        case "textbox": ("input", "text")
        case "searchbox": ("input", "search")
        case "combobox", "listbox": ("select", "select")
        case "checkbox": ("input", "checkbox")
        case "radio": ("input", "radio")
        case "option": ("option", nil)
        default: (nil, nil)
        }
    }

    static func playwrightResponseContainsSnapshot(_ text: String) -> Bool {
        playwrightSnapshotBody(from: text) != nil
    }

    private static func playwrightSnapshotBody(from text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let stateIndex = lines.firstIndex(where: {
            $0 == "### Page state"
        }), let snapshotIndex = lines[(stateIndex + 1)...].firstIndex(where: {
            $0 == "- Page Snapshot:" || $0 == "- Page Snapshot"
        }) else {
            return nil
        }
        let body = lines[(snapshotIndex + 1)...]
            .drop(while: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "```yaml" })
            .prefix(while: { $0.trimmingCharacters(in: .whitespacesAndNewlines) != "```" })
        return body.joined(separator: "\n")
    }

    static func remoteErrorMessage(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if object["isError"] as? Bool == true {
            if let message = object["message"] as? String, !message.isEmpty { return message }
            if let error = object["error"] as? String, !error.isEmpty { return error }
            return "MCP tool returned an error result."
        }
        if object["ok"] as? Bool == false {
            for key in ["reason", "message", "error", "detail"] {
                if let message = (object[key] as? String)?.nilIfBlank { return message }
            }
            return "MCP tool returned ok=false."
        }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String)?.nilIfBlank ?? "MCP JSON-RPC error"
        }
        return nil
    }

    static func allowedKey(_ key: String) -> Bool {
        if key.count == 1 { return true }
        return [
            "Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowUp", "ArrowDown",
            "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"
        ].contains(key)
    }

    static func normalizedObservation(
        rawResult: String,
        sessionId: String,
        backend: IOSWebMountBackendKind,
        snapshotID: String?,
        pageRevision: Int,
        semanticElements: [IOSWebMountDesktopSemanticElement]
    ) -> [String: Any] {
        let root: [String: Any]? = rawResult.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let payload: [String: Any]? = {
            guard let root else { return nil }
            for key in ["webmount", "observation", "snapshot"] {
                if let nested = root[key] as? [String: Any] { return nested }
            }
            return root
        }()
        let explicitSemanticVersion = (payload?["contract_version"] as? String)?.nilIfBlank
        let parseQuality: String
        if explicitSemanticVersion != nil {
            parseQuality = "versioned_structured"
        } else if root != nil {
            parseQuality = "structured_compat"
        } else if backend == .playwright_mcp, playwrightResponseContainsSnapshot(rawResult) {
            parseQuality = "playwright_accessibility"
        } else {
            parseQuality = "opaque"
        }

        let rawPage = payload?["page"] as? [String: Any]
        let rawURL = (rawPage?["url"] as? String)
            ?? (payload?["current_url"] as? String)
            ?? topLevelCurrentURL(from: rawResult, backend: backend)
        let rawTitle = (rawPage?["title"] as? String)
            ?? (payload?["title"] as? String)
            ?? playwrightPageTitle(from: rawResult)
        var page: [String: Any] = [
            "document_id": (payload?["document_id"] as? String)?.nilIfBlank ?? "remote:\(sessionId)",
            "page_revision": pageRevision,
            "snapshot_id": snapshotID ?? ""
        ]
        if let rawURL, let url = IOSWebMountRedactor.redactedURL(rawURL) { page["url"] = url }
        if let title = rawTitle?.nilIfBlank { page["title"] = IOSWebMountRedactor.redactedText(title) }
        if let readyState = (rawPage?["ready_state"] as? String)?.nilIfBlank
            ?? (payload?["ready_state"] as? String)?.nilIfBlank {
            page["ready_state"] = readyState
        }

        let accessibilityText = semanticElements.compactMap(\.name).joined(separator: "\n")
        let visibleText = ((payload?["visible_text"] as? String)
            ?? (payload?["text"] as? String)
            ?? (parseQuality == "playwright_accessibility" ? accessibilityText : ""))
        let links = (payload?["links"] as? [[String: Any]] ?? [])
            .prefix(100)
            .map { IOSWebMountRedactor.redactedJSONObject($0) }
        let visualCandidates = (payload?["visual_candidates"] as? [[String: Any]] ?? [])
            .prefix(100)
            .map { IOSWebMountRedactor.redactedJSONObject($0) }
        let interactiveElements = semanticElements
            .prefix(200)
            .map(\.contractDictionary)

        return [
            "semantic_contract_version": "webmount.semantic.v2",
            "source_contract_version": explicitSemanticVersion ?? "",
            "parse_quality": parseQuality,
            "document_id": page["document_id"] ?? "remote:\(sessionId)",
            "page_revision": pageRevision,
            "snapshot_id": snapshotID ?? "",
            "page": page,
            "visible_text": String(IOSWebMountRedactor.redactedText(visibleText).prefix(20_000)),
            "links": links,
            "interactive_elements": interactiveElements,
            "visual_candidates": visualCandidates
        ]
    }

    static func removingURLFields(from value: Any) -> Any {
        let urlKeys: Set<String> = ["current_url", "currentURL", "url", "origin"]
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                guard !urlKeys.contains(entry.key) else { return }
                result[entry.key] = removingURLFields(from: entry.value)
            }
        }
        if let array = value as? [Any] {
            return array.map { removingURLFields(from: $0) }
        }
        return value
    }

    static func topLevelCurrentURL(
        from text: String,
        backend: IOSWebMountBackendKind
    ) -> String? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["current_url", "currentURL", "url", "origin"] {
                if let url = (object[key] as? String)?.nilIfBlank {
                    return url
                }
            }
            let payload = (object["webmount"] as? [String: Any])
                ?? (object["observation"] as? [String: Any])
                ?? object
            if ["webmount.semantic.v2", "wm/2"].contains(payload["contract_version"] as? String ?? "") {
                if let url = (payload["current_url"] as? String)?.nilIfBlank {
                    return url
                }
                if let page = payload["page"] as? [String: Any],
                   let url = (page["url"] as? String)?.nilIfBlank {
                    return url
                }
            }
        }
        guard backend == .playwright_mcp else { return nil }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let stateIndex = lines.firstIndex(where: {
            $0 == "### Page state"
        }) else {
            return nil
        }
        for lineSlice in lines[(stateIndex + 1)...] {
            let line = String(lineSlice)
            if line == "- Page Snapshot:" || line == "- Page Snapshot" || line.hasPrefix("### ") {
                return nil
            }
            let prefix = "- Page URL:"
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfBlank
            }
        }
        return nil
    }

    static func pageIdentity(
        from text: String,
        backend: IOSWebMountBackendKind
    ) -> IOSWebMountDesktopPageIdentity? {
        let root: [String: Any]? = text.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let payload = (root?["webmount"] as? [String: Any])
            ?? (root?["observation"] as? [String: Any])
            ?? (root?["snapshot"] as? [String: Any])
            ?? root
        let documentID = (payload?["document_id"] as? String)?.nilIfBlank
            ?? ((payload?["page"] as? [String: Any])?["document_id"] as? String)?.nilIfBlank
        let rawURL = topLevelCurrentURL(from: text, backend: backend)
        let normalizedURL: String? = rawURL.flatMap { value in
            guard var components = URLComponents(string: value) else { return value.nilIfBlank }
            components.user = nil
            components.password = nil
            components.fragment = nil
            return components.string?.nilIfBlank
        }
        guard documentID != nil || normalizedURL != nil else { return nil }
        return IOSWebMountDesktopPageIdentity(documentID: documentID, currentURL: normalizedURL)
    }

    private static func playwrightPageTitle(from text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let stateIndex = lines.firstIndex(where: { $0 == "### Page state" }) else {
            return nil
        }
        for lineSlice in lines[(stateIndex + 1)...] {
            let line = String(lineSlice)
            if line == "- Page Snapshot:" || line == "- Page Snapshot" || line.hasPrefix("### ") {
                return nil
            }
            let prefix = "- Page Title:"
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfBlank
            }
        }
        return nil
    }

}
