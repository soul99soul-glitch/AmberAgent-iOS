import Foundation

// MARK: - Bridge RPC: `http` Namespace

extension DesktopPluginStore {
    func handleHTTPFetchAsyncBridgeCall(
        plugin: DesktopInstalledPlugin,
        args: [Any]
    ) async throws -> String {
        let urlString = (args.first as? String) ?? ""
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            throw DesktopRuntimeError.message("插件仅允许访问 HTTPS 地址：\(urlString)")
        }
        try requirePermission(plugin: plugin, permission: "http:\(host)")
        let options = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
        let httpMethod = ((options["method"] as? String) ?? "GET").uppercased()
        var headers: [String: String] = [:]
        if let rawHeaders = options["headers"] as? [String: Any] {
            for (k, v) in rawHeaders { headers[k] = String(describing: v) }
        }
        var bodyData: Data? = nil
        if let bodyStr = options["body"] as? String {
            bodyData = Data(bodyStr.utf8)
        } else if let bodyObj = options["body"], !(bodyObj is NSNull), JSONSerialization.isValidJSONObject(bodyObj) {
            bodyData = try? JSONSerialization.data(withJSONObject: bodyObj)
        }
        let (data, status) = try await performAuthorizedHTTP(
            plugin: plugin,
            urlString: urlString,
            method: httpMethod,
            headers: headers,
            body: bodyData
        )
        let bodyText = String(decoding: data, as: UTF8.self)
        let parsedJSON = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
        return try Self.encodeAnyJSON([
            "ok": (200...299).contains(status),
            "status": status,
            "body": bodyText,
            "text": bodyText,
            "json": parsedJSON
        ])
    }

    func handleHTTPSyncBridgeCall(
        plugin: DesktopInstalledPlugin,
        method: String,
        args: [Any],
        activeToolEffect: DesktopToolEffect?
    ) throws -> String {
        guard method == "fetch" else {
            throw DesktopRuntimeError.message("未知的 http 方法：\(method)")
        }
        let urlString = (args.first as? String) ?? ""
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            throw DesktopRuntimeError.message("插件仅允许访问 HTTPS 地址：\(urlString)")
        }
        try requirePermission(plugin: plugin, permission: "http:\(host)")
        let options = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
        let httpMethod = ((options["method"] as? String) ?? "GET").uppercased()
        if let effect = activeToolEffect, effect == .pure {
            throw DesktopRuntimeError.message("只读计算工具（effect=pure）禁止发起外部 HTTP 请求。")
        }
        if let effect = activeToolEffect, effect == .networkRead, httpMethod != "GET" && httpMethod != "HEAD" {
            throw DesktopRuntimeError.message("只读网络工具（effect=networkRead）仅允许发起 GET/HEAD 请求，禁止 \(httpMethod) 写操作。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.timeoutInterval = 20
        if let headers = options["headers"] as? [String: Any] {
            for (k, v) in headers { request.setValue(String(describing: v), forHTTPHeaderField: k) }
        }
        if let bodyString = options["body"] as? String {
            request.httpBody = Data(bodyString.utf8)
        } else if let bodyObj = options["body"],
                  !(bodyObj is NSNull),
                  JSONSerialization.isValidJSONObject(bodyObj),
                  let data = try? JSONSerialization.data(withJSONObject: bodyObj) {
            request.httpBody = data
        }
        return try performSynchronousHTTPRequest(request: request, host: host)
    }
}
