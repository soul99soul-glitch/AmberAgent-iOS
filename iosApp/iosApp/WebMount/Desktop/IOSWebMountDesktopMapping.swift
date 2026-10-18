import Foundation
import Observation
import WebKit


struct IOSWebMountDesktopMapping {
    let remoteToolName: String
    let mutating: Bool
    let requiresSnapshot: Bool
}

struct IOSWebMountDesktopToolDescriptor {
    let tool: IOSMcpTool
    let inputProperties: Set<String>?

    func explicitlySupports(_ name: String) -> Bool {
        inputProperties?.contains(name) == true
    }
}

enum IOSWebMountDesktopMappingPolicy {
    static let minimumToolNames: Set<String> = [
        "browser_navigate", "browser_snapshot"
    ]

    static let mappings: [String: IOSWebMountDesktopMapping] = [
        "wm_open": .init(remoteToolName: "browser_navigate", mutating: true, requiresSnapshot: false),
        "wm_forward": .init(remoteToolName: "browser_navigate_forward", mutating: true, requiresSnapshot: false),
        "wm_back": .init(remoteToolName: "browser_navigate_back", mutating: true, requiresSnapshot: false),
        "wm_state": .init(remoteToolName: "browser_snapshot", mutating: false, requiresSnapshot: false),
        "wm_observe": .init(remoteToolName: "browser_snapshot", mutating: false, requiresSnapshot: false),
        "wm_extract": .init(remoteToolName: "browser_extract", mutating: false, requiresSnapshot: false),
        "wm_get": .init(remoteToolName: "browser_get", mutating: false, requiresSnapshot: true),
        "wm_find": .init(remoteToolName: "browser_find", mutating: false, requiresSnapshot: false),
        "wm_click": .init(remoteToolName: "browser_click", mutating: true, requiresSnapshot: true),
        "wm_tap": .init(remoteToolName: "browser_click", mutating: true, requiresSnapshot: true),
        "wm_type": .init(remoteToolName: "browser_type", mutating: true, requiresSnapshot: true),
        "wm_keys": .init(remoteToolName: "browser_press_key", mutating: true, requiresSnapshot: true),
        "wm_select": .init(remoteToolName: "browser_select_option", mutating: true, requiresSnapshot: true),
        "wm_wait": .init(remoteToolName: "browser_wait_for", mutating: false, requiresSnapshot: false)
    ]

    static func resolvedMapping(
        toolName: String,
        arguments: [String: Any],
        tools: [String: IOSWebMountDesktopToolDescriptor]
    ) throws -> IOSWebMountDesktopMapping {
        guard let mapping = Self.mappings[toolName] else {
            throw IOSWebMountDesktopBackendError.mappingUnsupported(toolName)
        }
        guard tools[mapping.remoteToolName] != nil else {
            if ["wm_forward", "wm_extract", "wm_get", "wm_find"].contains(toolName) {
                throw IOSWebMountDesktopBackendError.mappingUnsupported(toolName)
            }
            throw IOSWebMountDesktopBackendError.gatewayToolMissing(mapping.remoteToolName)
        }
        if toolName == "wm_extract" {
            let mode = string(arguments, "mode") ?? "readable"
            guard ["readable", "interactive", "snapshot"].contains(mode) else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_extract/\(mode)")
            }
        }
        if toolName == "wm_get",
           (string(arguments, "kind") ?? "text") == "attr",
           let attrName = string(arguments, "attr_name") {
            if attrName.caseInsensitiveCompare("value") == .orderedSame {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_get/attr=value")
            }
            if IOSWebMountDesktopSemantics.isSensitiveTarget(attrName) {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_get/attr")
            }
        }
        return mapping
    }

    static func mappingIsAvailable(
        toolName: String,
        mapping: IOSWebMountDesktopMapping,
        tools: [String: IOSWebMountDesktopToolDescriptor]
    ) -> Bool {
        guard let remoteTool = tools[mapping.remoteToolName] else { return false }
        switch toolName {
        case "wm_extract":
            return remoteTool.explicitlySupports("mode")
        case "wm_get":
            return remoteTool.explicitlySupports("kind")
                && supportsTarget(remoteTool)
        case "wm_find":
            return remoteTool.explicitlySupports("text")
                || remoteTool.explicitlySupports("regex")
                || remoteTool.explicitlySupports("selector")
        case "wm_click", "wm_tap":
            return supportsTarget(remoteTool)
        case "wm_type":
            return supportsTarget(remoteTool)
                && (remoteTool.explicitlySupports("text") || remoteTool.explicitlySupports("value"))
        case "wm_select":
            return supportsTarget(remoteTool) && remoteTool.explicitlySupports("values")
        case "wm_keys":
            return remoteTool.explicitlySupports("key")
        case "wm_wait":
            return remoteTool.explicitlySupports("text")
                || remoteTool.explicitlySupports("textGone")
                || remoteTool.explicitlySupports("time")
                || remoteTool.explicitlySupports("selector")
                || remoteTool.explicitlySupports("url_contains")
                || remoteTool.explicitlySupports("ready_state")
                || remoteTool.explicitlySupports("dom_stable")
        default:
            return true
        }
    }

    private static func supportsTarget(_ remoteTool: IOSWebMountDesktopToolDescriptor) -> Bool {
        // Agent calls carry document-scoped semantic refs. A selector-only
        // gateway can still serve direct user actions, but it cannot satisfy
        // the Agent target contract and must not be advertised as available.
        remoteTool.explicitlySupports("target")
            || remoteTool.explicitlySupports("ref")
            || remoteTool.explicitlySupports("element")
    }

    static func inputProperties(from schema: String?) -> Set<String>? {
        guard let schema,
              let data = schema.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = object["properties"] as? [String: Any] else {
            return nil
        }
        return Set(properties.keys)
    }

    static func mappedArguments(
        toolName: String,
        arguments: [String: Any],
        remoteTool: IOSWebMountDesktopToolDescriptor,
        elements: [IOSWebMountDesktopSemanticElement]
    ) throws -> [String: Any] {
        switch toolName {
        case "wm_open":
            guard let url = string(arguments, "url") else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_open requires url.")
            }
            return applyingRemoteTimeout(
                from: arguments,
                remoteTool: remoteTool,
                to: ["url": url]
            )
        case "wm_back", "wm_forward", "wm_state", "wm_observe":
            return [:]
        case "wm_extract":
            let mode = string(arguments, "mode") ?? "readable"
            guard ["readable", "interactive", "snapshot"].contains(mode) else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_extract/\(mode)")
            }
            guard remoteTool.explicitlySupports("mode") else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_extract/\(mode)")
            }
            var mapped: [String: Any] = ["mode": mode]
            if let maxChars = arguments["max_chars"], remoteTool.explicitlySupports("max_chars") {
                mapped["max_chars"] = maxChars
            }
            if let maxLinks = arguments["max_links"], remoteTool.explicitlySupports("max_links") {
                mapped["max_links"] = maxLinks
            }
            return mapped
        case "wm_get":
            let kind = string(arguments, "kind") ?? "text"
            guard ["text", "value", "attr"].contains(kind),
                  remoteTool.explicitlySupports("kind") else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_get/\(kind)")
            }
            var mapped = try mappedTarget(arguments, remoteTool: remoteTool, toolName: toolName)
            if kind == "attr" {
                guard let attrName = string(arguments, "attr_name"),
                      remoteTool.explicitlySupports("attr_name") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_get/attr")
                }
                mapped["attr_name"] = attrName
            }
            if let maxChars = arguments["max_chars"], remoteTool.explicitlySupports("max_chars") {
                mapped["max_chars"] = maxChars
            }
            mapped["kind"] = kind
            return mapped
        case "wm_find":
            if arguments["locator"] != nil {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_find/locator")
            }
            if let selector = string(arguments, "selector") {
                guard remoteTool.explicitlySupports("selector") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_find/selector")
                }
                return ["selector": selector]
            }
            let text = string(arguments, "text")
            let regex = string(arguments, "regex")
            guard (text == nil) != (regex == nil) else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_find requires exactly one of text or regex.")
            }
            if let text {
                guard remoteTool.explicitlySupports("text") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_find/text")
                }
                return ["text": text]
            }
            guard remoteTool.explicitlySupports("regex"), let regex else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_find/regex")
            }
            return ["regex": regex]
        case "wm_click", "wm_tap":
            if arguments["x"] != nil || arguments["y"] != nil {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("coordinate tap")
            }
            var mapped = try mappedTarget(arguments, remoteTool: remoteTool, toolName: toolName)
            if toolName == "wm_click",
               let clickCount = (arguments["click_count"] as? NSNumber)?.intValue,
               clickCount == 2 {
                if remoteTool.explicitlySupports("click_count") {
                    mapped["click_count"] = 2
                } else if remoteTool.explicitlySupports("doubleClick") {
                    mapped["doubleClick"] = true
                } else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_click/click_count")
                }
            }
            return mapped
        case "wm_type":
            let target = try IOSWebMountDesktopSemantics.requireSafeTarget(arguments, toolName: toolName, elements: elements)
            guard let text = (arguments["text"] as? String) ?? (arguments["value"] as? String) else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_type requires text.")
            }
            var mapped = try mappedTarget(
                arguments,
                remoteTool: remoteTool,
                toolName: toolName,
                knownTarget: target
            )
            if remoteTool.explicitlySupports("text") {
                mapped["text"] = text
            } else if remoteTool.explicitlySupports("value") {
                mapped["value"] = text
            } else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_type/text")
            }
            if let submit = arguments["submit"] as? Bool, remoteTool.explicitlySupports("submit") {
                mapped["submit"] = submit
            }
            if let slowly = arguments["slowly"] as? Bool, remoteTool.explicitlySupports("slowly") {
                mapped["slowly"] = slowly
            }
            return mapped
        case "wm_keys":
            guard let key = string(arguments, "key") ?? string(arguments, "text"),
                  IOSWebMountDesktopSemantics.allowedKey(key),
                  remoteTool.explicitlySupports("key") else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_keys accepts one character or a bounded named key.")
            }
            return ["key": key]
        case "wm_select":
            let target = try IOSWebMountDesktopSemantics.requireSafeTarget(arguments, toolName: toolName, elements: elements)
            let values: [String]
            if let provided = arguments["values"] as? [String], !provided.isEmpty {
                values = provided
            } else if let value = string(arguments, "value") ?? string(arguments, "text") {
                values = [value]
            } else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_select requires a value.")
            }
            var mapped = try mappedTarget(
                arguments,
                remoteTool: remoteTool,
                toolName: toolName,
                knownTarget: target
            )
            guard remoteTool.explicitlySupports("values") else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_select/values")
            }
            mapped["values"] = values
            return mapped
        case "wm_wait":
            let condition = (string(arguments, "condition") ?? "dom_stable").lowercased()
            if condition == "text", let text = string(arguments, "text") {
                guard remoteTool.explicitlySupports("text") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/text")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["text": text])
            }
            if condition == "text_gone", let text = string(arguments, "text") {
                guard remoteTool.explicitlySupports("textGone") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/text_gone")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["textGone": text])
            }
            if condition == "delay", let milliseconds = number(arguments, "timeout_ms") {
                guard remoteTool.explicitlySupports("time") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/delay")
                }
                return ["time": min(max(milliseconds / 1_000, 0), 60)]
            }
            if condition == "selector", let target = string(arguments, "selector") ?? string(arguments, "target") {
                guard remoteTool.explicitlySupports("selector") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/selector")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["selector": target])
            }
            if condition == "url_contains", let fragment = string(arguments, "url_contains") {
                guard remoteTool.explicitlySupports("url_contains") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/url_contains")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["url_contains": fragment])
            }
            if condition == "ready_state", let readyState = string(arguments, "ready_state") {
                guard remoteTool.explicitlySupports("ready_state") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/ready_state")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["ready_state": readyState])
            }
            if condition == "dom_stable" {
                guard remoteTool.explicitlySupports("dom_stable") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/dom_stable")
                }
                return applyingRemoteTimeout(
                    from: arguments,
                    remoteTool: remoteTool,
                    to: ["dom_stable": true]
                )
            }
            throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/\(condition.nilIfBlank ?? "condition")")
        default:
            throw IOSWebMountDesktopBackendError.mappingUnsupported(toolName)
        }
    }

    static func semanticTarget(
        _ arguments: [String: Any],
        toolName: String,
        knownTarget: String? = nil
    ) throws -> String {
        if let knownTarget { return knownTarget }
        let target = string(arguments, "target")
        let selector = string(arguments, "selector")
        if let target {
            if let selector, selector != target {
                throw IOSWebMountDesktopBackendError.invalidArguments("\(toolName) received conflicting target and selector values.")
            }
            return target
        }
        guard let selector else {
            throw IOSWebMountDesktopBackendError.invalidArguments("\(toolName) requires a semantic target from the latest snapshot.")
        }
        return selector
    }

    private static func mappedTarget(
        _ arguments: [String: Any],
        remoteTool: IOSWebMountDesktopToolDescriptor,
        toolName: String,
        knownTarget: String? = nil
    ) throws -> [String: Any] {
        let target = try semanticTarget(arguments, toolName: toolName, knownTarget: knownTarget)
        // target is the canonical Agent input. A matching selector may be
        // accepted for compatibility, but must not force selector mapping on a
        // gateway that only exposes target/ref/element.
        if string(arguments, "target") == nil, string(arguments, "selector") != nil {
            guard remoteTool.explicitlySupports("selector") else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("\(toolName)/selector")
            }
            return ["selector": target]
        }
        if remoteTool.explicitlySupports("target") {
            return ["target": target]
        }
        if remoteTool.explicitlySupports("ref") {
            return ["ref": target]
        }
        if remoteTool.explicitlySupports("element") {
            return ["element": target]
        }
        throw IOSWebMountDesktopBackendError.mappingUnsupported("\(toolName)/target")
    }

    static func string(_ values: [String: Any], _ key: String) -> String? {
        (values[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func number(_ values: [String: Any], _ key: String) -> Double? {
        (values[key] as? NSNumber)?.doubleValue
    }

    private static func applyingRemoteTimeout(
        from arguments: [String: Any],
        remoteTool: IOSWebMountDesktopToolDescriptor,
        to mapped: [String: Any]
    ) -> [String: Any] {
        guard let timeout = number(arguments, "timeout_ms") else { return mapped }
        var result = mapped
        let clamped = Int(timeout).clamped(to: 100...30_000)
        if remoteTool.explicitlySupports("timeout_ms") {
            result["timeout_ms"] = clamped
        } else if remoteTool.explicitlySupports("timeout") {
            result["timeout"] = clamped
        }
        if let stable = number(arguments, "stable_ms"),
           remoteTool.explicitlySupports("stable_ms") {
            result["stable_ms"] = Int(stable).clamped(to: 50...5_000)
        }
        return result
    }

}
