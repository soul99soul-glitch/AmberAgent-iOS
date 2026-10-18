import Foundation

/// Recipe manifests used by the lifecycle, reload, and approval suites.
extension IOSRecipeIntegrationTestCase {
    /// 单 step pure 读 recipe：读取必然缺失的文件（隔离 temp workspace 为空）。
    func readMissingRecipeJSON(version: String) throws -> Data {
        let dict: [String: Any] = [
            "schema": "amber.recipe.v1",
            "name": "missing_reader",
            "version": version,
            "description": "读取一个必然不存在的文件。",
            "inputs": ["path": "string"],
            "steps": [
                ["id": "read", "tool": "workspace_file_read",
                 "arguments": ["path": "${input.path}"]],
            ],
            "outputs": ["text": "${step.read.output.text}"],
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    // MARK: Manifest builders (test data, not assertions)

    func listingRecipeJSON(version: String, name: String = "catalog_probe") throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": name,
            "version": version,
            "description": "列出当前工具目录并返回总数。",
            "inputs": [:],
            "steps": [
                ["id": "list", "tool": "tools_list", "arguments": [:]],
            ],
            "outputs": ["tool_count": "${step.list.output.total}"],
        ])
    }

    func listingRecipeV2JSON(version: String) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": "catalog_probe",
            "version": version,
            "description": "列出工具目录两次。",
            "inputs": [:],
            "steps": [
                ["id": "list", "tool": "tools_list", "arguments": [:]],
                ["id": "list_again", "tool": "tools_list", "arguments": [:]],
            ],
            "outputs": ["tool_count": "${step.list_again.output.total}"],
        ])
    }

    func twoMutationRecipeJSON(version: String) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": "double_save",
            "version": version,
            "description": "列出工具目录并写入两个 Workspace 文件。",
            "inputs": ["path_a": "string", "path_b": "string"],
            "steps": [
                ["id": "list", "tool": "tools_list", "arguments": [:]],
                ["id": "save_a", "tool": "workspace_file_write",
                 "arguments": ["path": "${input.path_a}", "content": "${step.list.output.status}"]],
                ["id": "save_b", "tool": "workspace_file_write",
                 "arguments": ["path": "${input.path_b}", "content": "${step.save_a.output.id}"]],
            ],
            "outputs": [
                "path_a_out": "${step.save_a.output.path}",
                "path_b_out": "${step.save_b.output.path}",
            ],
        ])
    }

    func singleStepRecipeJSON(
        name: String,
        tool: String,
        arguments: [String: Any]
    ) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": name,
            "version": "1.0.0",
            "description": "Apple capability gate regression.",
            "inputs": [:],
            "steps": [["id": "action", "tool": tool, "arguments": arguments]],
            "outputs": ["status": "${step.action.output.status}"],
        ])
    }

    func mutatingRecipeJSON(version: String) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": "digest_save",
            "version": version,
            "description": "列出工具目录并把结果写入 Workspace。",
            "inputs": ["output_path": "string"],
            "steps": [
                ["id": "list", "tool": "tools_list", "arguments": [:]],
                ["id": "save", "tool": "workspace_file_write",
                 "arguments": ["path": "${input.output_path}", "content": "${step.list.output.status}"]],
            ],
            "outputs": ["file_path": "${step.save.output.path}"],
        ])
    }

    func webMountCheckoutRecipeJSON(
        version: String,
        sessionId: String,
        snapshotId: String,
        targetRef: String
    ) throws -> Data {
        try jsonData([
            "schema": "amber.recipe.v1",
            "name": "webmount_checkout",
            "version": version,
            "description": "检查付款并提交订单。",
            "inputs": [:],
            "steps": [[
                "id": "pay_and_submit",
                "tool": "wm_click",
                "arguments": [
                    "session_id": sessionId,
                    "snapshot_id": snapshotId,
                    "target": targetRef,
                ],
            ]],
            "outputs": ["status": "${step.pay_and_submit.output.status}"],
        ])
    }

}
