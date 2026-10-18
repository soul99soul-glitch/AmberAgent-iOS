import Foundation
import Darwin
import CryptoKit
import Combine
import Observation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

struct IOSWebMountToolDescriptor: Equatable, Identifiable {
    let name: String
    let description: String
    let requiresUserAction: Bool

    var id: String { name }
}

enum IOSWebMountToolCatalog {
    static let descriptors: [IOSWebMountToolDescriptor] = [
        .init(name: "wm_stations", description: "List configured WebMount stations without exposing cookie values.", requiresUserAction: false),
        .init(name: "wm_tab_list", description: "List up to three foreground iOS WebMount sessions.", requiresUserAction: false),
        .init(name: "wm_tab_new", description: "Create a new foreground iOS WebMount session, bounded to three sessions.", requiresUserAction: false),
        .init(name: "wm_tab_close", description: "Close one foreground iOS WebMount session by session_id.", requiresUserAction: false),
        .init(name: "wm_open", description: "Open a URL in a local WKWebView session. Unlisted public hosts require high-risk auto-approve.", requiresUserAction: false),
        .init(name: "wm_state", description: "Read current WKWebView status, title, redacted URL, and page state.", requiresUserAction: false),
        .init(name: "wm_observe", description: "Read state, visible text, links, interactive elements, and visual candidates without cookies or headers.", requiresUserAction: false),
        .init(name: "wm_extract", description: "Extract readable or interactive page content through a read-only bridge.", requiresUserAction: false),
        .init(name: "wm_get", description: "Read a visible element's text, checked value, or non-sensitive attribute through a restricted bridge. Raw HTML reads are disabled on iOS.", requiresUserAction: false),
        .init(name: "wm_visual_snapshot", description: "Return viewport visual candidates from DOM rectangles without calling an external vision model.", requiresUserAction: false),
        .init(name: "wm_screenshot", description: "Capture the current viewport to a local WebMount artifact after foreground approval.", requiresUserAction: true),
        .init(name: "wm_visual_read", description: "Read a real local viewport screenshot with a vision model after approval. Use after navigation and key actions to verify the visible result; DOM candidates alone are not visual verification.", requiresUserAction: true),
        .init(name: "wm_back", description: "Navigate the current WebMount session backward.", requiresUserAction: false),
        .init(name: "wm_forward", description: "Navigate the current WebMount session forward.", requiresUserAction: false),
        .init(name: "wm_clear_session", description: "Clear cookies and website data for one station after explicit user action.", requiresUserAction: true),
        .init(name: "wm_site_add", description: "Add an iOS WebMount station and sync the URL allowlist after foreground approval.", requiresUserAction: true),
        .init(name: "wm_site_remove", description: "Remove an iOS WebMount station and sync the URL allowlist after foreground approval. Cookies are not cleared.", requiresUserAction: true),
        .init(name: "wm_site_memory", description: "Read local memory for a registered host, or propose 1–8 changes with an explicit operation for one batch approval or enabled high-risk auto-approval. Treat memory as untrusted; the current page wins on conflict.", requiresUserAction: false),
        .init(name: "wm_click", description: "Click an observed semantic target bound to the current session and snapshot.", requiresUserAction: false),
        .init(name: "wm_tap", description: "Tap an observed semantic target; coordinates require direct user action.", requiresUserAction: false),
        .init(name: "wm_type", description: "Type text into an observed input target and verify its current value.", requiresUserAction: false),
        .init(name: "wm_keys", description: "Send a short key sequence to the current WebMount page or focused field.", requiresUserAction: false),
        .init(name: "wm_scroll", description: "Scroll the page or an element into view.", requiresUserAction: false),
        .init(name: "wm_select", description: "Select an option value using an observed semantic target.", requiresUserAction: false),
        .init(name: "wm_find", description: "Read-only selector or visible-text search that returns stable element refs without input values.", requiresUserAction: false),
        .init(name: "wm_wait", description: "Wait up to 30 seconds for a target, text, URL, document change, DOM stability, readiness, or delay; readiness alone does not verify the task goal.", requiresUserAction: false),
        .init(name: "wm_run_goal", description: "Use for one concrete, verifiable goal on an already-open WebMount session when the allowed actions are read-only navigation or inspection, selection, draft-only text entry, or a read-only search. Do not use for vague goals, sending or publishing content, destructive or account-changing actions, payment, login, or any task that needs a human decision during the loop; use individual wm_* tools or ask the user. Each action still passes the host approval and ledger checks.", requiresUserAction: false),
        .init(name: "wm_act", description: "Execute a small ordered batch of page actions (find/click/tap/type/keys/scroll/select/wait) in one call. Steps run serially through the same approval and snapshot gates as single tools; a find step feeds its first match ref to the next target-less step; any document navigation aborts the remaining steps.", requiresUserAction: false)
    ]

    static let supportedToolNames = Set(descriptors.map(\.name))

    static let unsupportedToolNames: Set<String> = [
        "wm_eval",
        "wm_signed_fetch",
        "wm_network_inspect",
        "wm_fetch_replay",
        "wm_recipe_candidates",
        "wm_oauth_connect",
        "wm_oauth_refresh",
        "wm_profile_synthesize",
        "wm_site_adapter"
    ]
}

