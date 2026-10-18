# 第 1 阶段：完成

8 项已修复：S1/S2/CRED-1/CRED-2/KMP-01/KMP-02/PHONE-1/PHONE-2。

新增反例修复前实际失败：iOS 11 项中 9 失败、2 正常控制通过；OpenAI 5 项中 4 失败、Gemini 5 项中 1 失败；Phone scope 2 项失败。日志均保存在 `/tmp/amber-audit-20261018-current`。

修复后：iOS 相关 12 个 suite 共 248 项全部通过；OpenAI 全模块 81 与 Shared 全模块 53 全部通过；Phone SwiftPM 107 项全部通过。iOS 构建同时实际消费本仓 Gradle Shared.framework。保留既有 settings fixture State runtime warning，不据此声称产品缺陷。

首次 iOS green 因提前准备的 Search 测试 fixture 缺少 MainActor 而编译失败、零用例；只标注该 fixture 后，r2 实际通过。未削弱业务断言或跳过用例。

[独立 review](reviews/phase-1-independent-review.md) PASS；[S1 额外 peer](reviews/phase1-s1-peer.md) PASS。两者均未参与对应实现，Root 已补齐实际 green。

真实 provider、模型编辑器人工交互与物理手机体验未由上述模拟/注入测试替代。
