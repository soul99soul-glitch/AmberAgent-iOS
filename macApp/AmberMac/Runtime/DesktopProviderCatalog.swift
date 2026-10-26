import Foundation
import Observation

struct DesktopCatalogModel: Codable, Equatable, Identifiable, Sendable {
    var modelID: String
    var name: String
    var contextWindowTokens: Int?
    var supportsVision: Bool?
    var id: String { modelID }
}

@MainActor protocol DesktopModelCatalog {
    func models(for configuration: DesktopProviderConfiguration, apiKey: String) async throws -> [DesktopCatalogModel]
    func testConnection(for configuration: DesktopProviderConfiguration, apiKey: String) async throws
}

enum DesktopModelCatalogMerge {
    static func merge(_ incoming: [DesktopCatalogModel], into existing: [DesktopModelConfiguration]) -> [DesktopModelConfiguration] {
        var known = Set(existing.map(\.modelID))
        return existing + incoming.compactMap { item in
            guard known.insert(item.modelID).inserted else { return nil }
            return DesktopModelConfiguration(modelID: item.modelID, name: item.name,
                contextWindowTokens: item.contextWindowTokens, supportsVision: item.supportsVision)
        }
    }
}

@MainActor @Observable final class DesktopCatalogRequest {
    private(set) var isLoading = false
    private(set) var models: [DesktopCatalogModel] = []
    private(set) var status: String?
    private(set) var failed = false
    private(set) var isTestingConnection = false
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?

    func cancel() {
        token = nil; task?.cancel(); task = nil
        isLoading = false; models = []; status = nil; failed = false; isTestingConnection = false
    }

    func waitUntilIdle() async { await task?.value }

    func fetch(configuration: DesktopProviderConfiguration, apiKey: String, catalog: any DesktopModelCatalog, testOnly: Bool = false) {
        cancel()
        let request = UUID()
        token = request; isLoading = true; isTestingConnection = testOnly
        task = Task {
            defer { if token == request { isLoading = false; task = nil } }
            do {
                if testOnly {
                    try await catalog.testConnection(for: configuration, apiKey: apiKey)
                    guard token == request else { return }
                    status = "模型已完成最小生成请求。"
                } else {
                    let result = try await catalog.models(for: configuration, apiKey: apiKey)
                    guard token == request else { return }
                    models = result
                    status = result.isEmpty ? "服务商未返回模型，可继续手填模型 ID。" : "已获取 \(result.count) 个模型，选择添加后保存。"
                }
            } catch is CancellationError {
            } catch {
                guard token == request else { return }
                failed = true
                status = "请求失败，请核对网络、协议、API 地址与凭证后重试。"
            }
        }
    }
}
