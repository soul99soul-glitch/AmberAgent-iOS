import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

@MainActor
final class IOSWebMountRegistryPolicyTests: IOSWebMountToolTestCase {
    func testWebMountRegistrySeedsAndPersists() throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)

        XCTAssertEqual(Set(registry.sites.map(\.id)), [
            "hackernews",
            "reddit",
            "github",
            "bilibili",
            "x_com",
            "weibo",
            "juejin",
            "zhihu",
            "feishu_docs"
        ])

        registry.setEnabled(id: "github", enabled: true)
        let reloaded = IOSWebMountRegistry(userDefaults: defaults)
        XCTAssertEqual(reloaded.site(id: "github")?.enabled, true)
    }

    func testWebMountDisabledStationStillAllowsExplicitForegroundUserOpen() async throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let site = try XCTUnwrap(registry.site(id: "hackernews"))
        XCTAssertFalse(site.enabled)
        let runtime = MockWebMountRuntime(sessionId: "foreground-disabled-station")
        let controller = IOSWebMountController(
            registry: registry,
            settings: IOSWebMountSettings(userDefaults: defaults),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() },
            resolveHost: { _ in ["93.184.216.34"] }
        )

        let snapshot = await controller.openForUser(site: site, sessionId: runtime.snapshot.sessionId)

        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(runtime.openedURLs, [URL(string: "https://news.ycombinator.com")!])
        XCTAssertEqual(
            controller.sessionStore.record(sessionId: runtime.snapshot.sessionId)?.controlOwner,
            .user
        )
    }

    func testWebMountHumanAddressEntryAllowsPublicLoginWithoutEnablingAgentStation() async throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let site = try XCTUnwrap(registry.site(id: "weibo"))
        let runtime = MockWebMountRuntime(sessionId: "human-login")
        let settings = IOSWebMountSettings(userDefaults: defaults)
        let controller = IOSWebMountController(registry: registry, settings: settings, runtime: runtime,
            resolveHost: { host in host == "private.example" ? ["10.0.0.1"] : ["93.184.216.34"] })
        let originalHosts = settings.allowedHosts
        let originalSites = registry.sites
        let login = "https://unknown-login.example/signin"
        let opened = await controller.openForUser(site: site, sessionId: runtime.snapshot.sessionId, url: login)
        XCTAssertEqual(opened.status, .ready)
        XCTAssertEqual(runtime.openedURLs.last?.absoluteString, login)
        XCTAssertEqual(registry.sites, originalSites)
        XCTAssertEqual(settings.allowedHosts, originalHosts)
        XCTAssertFalse(try XCTUnwrap(registry.site(id: "weibo")).enabled)

        let denied = await controller.openForUser(site: site, sessionId: runtime.snapshot.sessionId,
                                                   url: "https://private.example/login")
        XCTAssertEqual(denied.status, .failed)
        XCTAssertEqual(runtime.openedURLs.count, 1)
        let missing = await controller.openForUser(site: site, sessionId: "missing-session", url: login)
        XCTAssertEqual(missing.status, .failed)
        XCTAssertEqual(runtime.openedURLs.count, 1, "An invalid session must not open the current session instead")
    }

    func testWebMountUnlistedHumanNavigationDoesNotCreateSyntheticStationBinding() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let sessionID = controller.sessionStore.currentSessionId
        _ = try controller.sessionStore.acquireAgentControl(sessionId: sessionID, runId: "login-run", conversationId: "login-chat")
        let site = IOSWebMountSite(id: "unlisted:\(sessionID)", displayName: "Public login",
            homepageURL: "https://unlisted.amber.invalid/", authKind: .anonymous, loginCookieName: nil,
            nativeAdapterId: nil, iconKey: nil, oauthProviderId: nil,
            allowedHosts: ["unlisted.amber.invalid"], enabled: false, addedAtMillis: 0)
        let opened = await controller.openForUser(site: site, sessionId: sessionID)
        XCTAssertEqual(opened.status, .ready)
        XCTAssertNil(controller.sessionStore.record(sessionId: sessionID)?.siteId)
        _ = try controller.sessionStore.handBackToAgent(sessionId: sessionID)
        let state = try jsonObject(await controller.execute(toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": sessionID]), isUserInitiated: false,
            context: IOSWebMountExecutionContext(runId: "login-run", conversationId: "login-chat"), allowUnlistedHosts: true))
        XCTAssertEqual(state["ok"] as? Bool, true)
    }

    func testWebMountRegistryRestoresSeedsWhenPersistedPayloadIsUnreadable() throws {
        let defaults = isolatedDefaults()
        defaults.set(Data([0x7b]), forKey: "app.amber.ios.webmount.sites.v1")
        defaults.set(true, forKey: "app.amber.ios.webmount.seeded.v1")

        let registry = IOSWebMountRegistry(userDefaults: defaults)

        XCTAssertEqual(registry.sites.count, 9)
        XCTAssertNotNil(registry.site(id: "github"))
    }

    func testWebMountRegistryAddRemoveRestore() throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)

        let custom = try registry.addCustomSite(
            displayName: "Example Docs",
            homepageURL: "https://docs.example.com/start?token=secret",
            needsLogin: true,
            loginCookieName: "sid"
        )
        XCTAssertTrue(custom.id.hasPrefix("user_"))
        XCTAssertEqual(custom.allowedHosts, ["docs.example.com"])
        XCTAssertTrue(registry.remove(id: "github"))
        XCTAssertNil(registry.site(id: "github"))
        XCTAssertEqual(registry.restoreMissingSeeds(), 1)
        XCTAssertNotNil(registry.site(id: "github"))
    }

    func testWebMountSettingsDefaults() {
        let settings = IOSWebMountSettings(userDefaults: isolatedDefaults())

        XCTAssertTrue(settings.globalEnabled)
        XCTAssertTrue(settings.allowedHosts.contains("github.com"))
        XCTAssertTrue(settings.allowedSchemes.contains("http"))
        XCTAssertTrue(settings.allowedSchemes.contains("https"))
    }

    func testWebMountURLPolicyRejectsSchemeAndHostOutsideAllowlist() async throws {
        let settings = IOSWebMountSettings(userDefaults: isolatedDefaults())
        let policy = IOSWebMountURLPolicy(settings: settings)
        let highRiskPolicy = IOSWebMountURLPolicy(settings: settings, allowUnlistedHosts: true)

        XCTAssertNotNil(try? policy.validate("https://github.com/login").get())
        XCTAssertEqual(
            policy.validate("javascript:alert(1)").failure,
            .unsupportedScheme("javascript")
        )
        XCTAssertEqual(
            policy.validate("data:text/html,hi").failure,
            .unsupportedScheme("data")
        )
        XCTAssertEqual(
            policy.validate("https://evil.example.com/").failure,
            .hostNotAllowed("evil.example.com")
        )
        XCTAssertNotNil(try? highRiskPolicy.validate("https://evil.example.com/").get())
        XCTAssertEqual(
            highRiskPolicy.validate("https://127.0.0.1/admin").failure,
            .privateHostNotAllowed("127.0.0.1")
        )
        XCTAssertEqual(
            highRiskPolicy.validate("https://user:secret@evil.example.com/").failure,
            .embeddedCredentialsNotAllowed
        )
        XCTAssertEqual(
            policy.validate("https://user:secret@github.com/").failure,
            .embeddedCredentialsNotAllowed
        )
        let privateResolution = await highRiskPolicy.validateResolvedPublicHost(
            "https://internal.example/",
            resolveHost: { _ in ["10.0.0.8"] }
        )
        XCTAssertEqual(privateResolution.failure, .resolvedHostNotPublic("internal.example"))
    }

    func testWebMountFragmentNavigationFinishesWithoutReloadingDocument() async throws {
        let runtime = IOSWebMountWKRuntime()
        let webView = try XCTUnwrap(runtime.webView)
        webView.loadHTMLString(
            "<html><body><p>local fixture</p><script>window.fixtureMarker='original';</script></body></html>",
            baseURL: URL(string: "https://webmount.invalid/")
        )
        for _ in 0..<100 {
            if runtime.snapshot.status == .ready { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(runtime.snapshot.status, .ready)
        let settings = IOSWebMountSettings(userDefaults: isolatedDefaults())
        runtime.setNavigationPolicy(
            IOSWebMountURLPolicy(settings: settings, allowUnlistedHosts: true, allowFakeIPFallback: true, resolvePublicHost: { _ in ["93.184.216.34"] }),
            site: nil,
            resolveHost: { _ in ["198.18.0.34"] }
        )
        let result = await runtime.open(URL(string: "https://webmount.invalid/#/login")!, timeoutMillis: 1_000)
        XCTAssertEqual(result.status, .ready, result.error ?? "")
        XCTAssertNil(result.error)
        let hash = try await webView.evaluateJavaScript("location.hash") as? String
        XCTAssertEqual(hash, "#/login")
        let marker = try await webView.evaluateJavaScript("window.fixtureMarker") as? String
        XCTAssertEqual(marker, "original")
        let repeated = await runtime.open(URL(string: "https://webmount.invalid/#/login")!, timeoutMillis: 1_000)
        XCTAssertEqual(repeated.status, .ready, repeated.error ?? "")

        runtime.setNavigationPolicy(
            IOSWebMountURLPolicy(settings: settings, allowUnlistedHosts: true),
            site: nil,
            resolveHost: { _ in ["10.0.0.8"] }
        )
        let rejected = await runtime.open(URL(string: "https://webmount.invalid/#/blocked")!, timeoutMillis: 1_000)
        XCTAssertEqual(rejected.status, .failed)
        XCTAssertTrue(rejected.error?.contains("DNS returned a non-public") == true)
        let retainedHash = try await webView.evaluateJavaScript("location.hash") as? String
        XCTAssertEqual(retainedHash, "#/login")
    }

    func testWebMountDNSFailuresAreDistinctFromPrivateHostLiterals() async throws {
        let policy = IOSWebMountURLPolicy(
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            allowUnlistedHosts: true
        )
        for addresses in [["10.0.0.34"], ["93.184.216.34", "10.0.0.8"]] {
            let result = await policy.validateResolvedPublicHost(
                "https://unlisted.amber.invalid/", resolveHost: { _ in addresses }
            )
            XCTAssertEqual(result.failure, .resolvedHostNotPublic("unlisted.amber.invalid"))
            XCTAssertEqual(result.failure?.errorCode, "dns_non_public_address")
        }
        let empty = await policy.validateResolvedPublicHost("https://unlisted.amber.invalid/", resolveHost: { _ in [] })
        XCTAssertEqual(empty.failure, .hostResolutionFailed("unlisted.amber.invalid"))
        let failed = await policy.validateResolvedPublicHost("https://unlisted.amber.invalid/", resolveHost: { _ in
            throw URLError(.cannotFindHost)
        })
        XCTAssertEqual(failed.failure, .hostResolutionFailed("unlisted.amber.invalid"))
        XCTAssertEqual(failed.failure?.errorCode, "dns_resolution_failed")
        for host in ["github.com", "www.icloud.com", "account.apple.com", "idmsa.apple.com", "example.com"] {
            let result = await policy.validateResolvedPublicHost(
                "https://\(host)/", resolveHost: { _ in ["93.184.216.34"] }
            )
            XCTAssertNotNil(try? result.get(), host)
        }
    }

    func testWebMountHighRiskApprovalPreservesRegisteredHostPolicyWithProxyDNS() async throws {
        let settings = IOSWebMountSettings(userDefaults: isolatedDefaults())
        let addedHosts = ["www.icloud.com", "idmsa.apple.com"]
        for autoApprove in [false, true] {
            let policy = IOSWebMountURLPolicy(
                settings: settings,
                extraAllowedHosts: addedHosts,
                allowUnlistedHosts: autoApprove
            )
            for host in ["github.com"] + addedHosts {
                let result = await policy.validateResolvedPublicHost(
                    "https://\(host)/#/login", resolveHost: { _ in ["198.18.0.34"] }
                )
                XCTAssertNotNil(try? result.get(), "\(host), autoApprove=\(autoApprove)")
            }
        }
        let policy = IOSWebMountURLPolicy(settings: settings, allowUnlistedHosts: true)
        XCTAssertEqual(
            policy.validate("https://198.18.0.34/").failure,
            .privateHostNotAllowed("198.18.0.34")
        )
    }

    func testWebMountRedactionRemovesSensitiveValuesAndURLQuery() throws {
        let redacted = IOSWebMountRedactor.redactedJSONObject([
            "url": "https://example.com/path?token=secret#frag",
            "href": "https://example.com/next?auth=secret",
            "cookie": "sid=secret",
            "nested": [
                "Authorization": "Bearer secret",
                "verificationCode": "654321",
                "otpCode": "123456",
                "cardNumber": "4111111111111111",
                "cvv2": "123",
                "billingAddress": "private address",
                "验证码": "999999",
                "卡号": "5555555555554444"
            ]
        ])
        let json = IOSWebMountController.json(redacted)
        let object = try jsonObject(json)

        XCTAssertEqual(object["url"] as? String, "https://example.com/path")
        XCTAssertEqual(object["href"] as? String, "https://example.com/next")
        XCTAssertEqual(IOSWebMountRedactor.redactedURL("not a URL with token=secret"), "[redacted-url]")
        XCTAssertFalse(json.contains("token=secret"))
        XCTAssertFalse(json.contains("auth=secret"))
        XCTAssertFalse(json.contains("sid=secret"))
        XCTAssertFalse(json.contains("Bearer secret"))
        XCTAssertFalse(json.contains("654321"))
        XCTAssertFalse(json.contains("123456"))
        XCTAssertFalse(json.contains("4111111111111111"))
        XCTAssertFalse(json.contains("private address"))
        XCTAssertFalse(json.contains("999999"))
        XCTAssertFalse(json.contains("5555555555554444"))
    }

    func testWebMountRedactionScrubsSensitivePlainStrings() {
        let text = IOSWebMountRedactor.redactedText(
            #"Visit https://example.com/reset/token-opaque?token=secret, use Authorization: Bearer abcdef123456, Password: hunter2, OTP: 123456, 验证码 654321, Card Number: 4111 1111 1111 1111, CVV: 123, and {"password":"json-secret"}"#
        )

        XCTAssertFalse(text.contains("token=secret"))
        XCTAssertFalse(text.contains("token-opaque"))
        XCTAssertFalse(text.contains("abcdef123456"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("123456"))
        XCTAssertFalse(text.contains("654321"))
        XCTAssertFalse(text.contains("4111 1111 1111 1111"))
        XCTAssertFalse(text.contains("CVV: 123"))
        XCTAssertFalse(text.contains("json-secret"))
        XCTAssertTrue(text.contains("https://example.com/redacted"))
    }

    func testWebMountScreenshotArtifactsExpireAndDeleteWithSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webmount-artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = IOSWebMountScreenshotCapture(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            width: 20,
            height: 10,
            format: "png"
        )
        let now: Int64 = 1_000
        let first = try IOSWebMountScreenshotArtifactStore.save(
            capture,
            sessionId: "session-a",
            rootDirectory: root,
            nowMillis: now
        )
        _ = try IOSWebMountScreenshotArtifactStore.save(
            capture,
            sessionId: "session-b",
            rootDirectory: root,
            nowMillis: now
        )
        let directory = root
            .appendingPathComponent("AmberWorkspace/WebMount/screenshots", isDirectory: true)
        XCTAssertEqual(first["expires_at_ms"] as? Int64, now + IOSWebMountScreenshotArtifactStore.retentionMillis)
        XCTAssertEqual(first["contains_unredacted_viewport"] as? Bool, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)

        IOSWebMountScreenshotArtifactStore.deleteArtifacts(sessionId: "session-a", rootDirectory: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        IOSWebMountScreenshotArtifactStore.cleanupExpired(
            rootDirectory: root,
            nowMillis: now + IOSWebMountScreenshotArtifactStore.retentionMillis
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testWebMountToolCatalogAndUnsupportedResult() {
        XCTAssertEqual(IOSWebMountToolCatalog.supportedToolNames.count, 28)
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_run_goal"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_act"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_open"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_tab_list"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_tab_new"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_tab_close"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_observe"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_visual_snapshot"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_screenshot"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_site_add"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_site_remove"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_site_memory"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_click"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_tap"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_type"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_keys"))
        XCTAssertTrue(IOSWebMountToolCatalog.unsupportedToolNames.contains("wm_eval"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_visual_read"))
        XCTAssertTrue(IOSWebMountToolCatalog.unsupportedToolNames.contains("wm_signed_fetch"))
        XCTAssertTrue(IOSWebMountController.unsupportedToolResult(toolName: "wm_eval").contains("unsupported"))
    }

}

private extension Result where Success == URL, Failure == IOSWebMountURLPolicyError {
    var failure: IOSWebMountURLPolicyError? {
        switch self {
        case .success:
            nil
        case .failure(let error):
            error
        }
    }
}

