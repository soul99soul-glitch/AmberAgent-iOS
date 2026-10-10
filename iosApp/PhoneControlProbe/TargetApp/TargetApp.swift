import SwiftUI

@main
struct PhoneControlTargetApp: App {
    var body: some Scene { WindowGroup { TargetView() } }
}

private struct TargetView: View {
    @State private var query = ""
    @State private var result = "尚未搜索"
    @State private var count = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("可逆操作") {
                    TextField("输入测试文字", text: $query)
                        .accessibilityIdentifier("probe.query")
                    Button("搜索") { result = query.isEmpty ? "请输入文字" : "搜索结果：\(query)" }
                        .accessibilityIdentifier("probe.search")
                    Text(result).accessibilityIdentifier("probe.result")
                }
                Section("后台链路验证") {
                    Button("计数加一") { count += 1 }
                        .accessibilityIdentifier("probe.increment")
                    Text("当前计数：\(count)").accessibilityIdentifier("probe.count")
                    Button("重置") { count = 0; query = ""; result = "尚未搜索" }
                        .accessibilityIdentifier("probe.reset")
                }
            }
            .navigationTitle("自动化靶场")
        }
    }
}
