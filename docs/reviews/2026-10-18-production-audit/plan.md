# 当前工作树生产路径审查与修复

基线：`codex/swift-modularization-1500` / `b98bd6f0f2f82dd9492ff021e53d03bfe26d2dce`。包含 tracked WIP 和 untracked 拆分文件。

目标：广泛审查本产品生产路径；候选问题二次复核触发条件、可达性和实际影响，仅修复确认问题。保护既有 WIP，不提交、推送、删除死代码或修改其他产品。

完成标准：问题与排除项可追溯；确认问题分阶段修复；每阶段由独立 subagent 复核；受影响测试和构建通过；明确模拟器、真机和真实 provider 的证据边界。

阶段：
1. 并行审查聊天/后台、存储/设置、工具/权限、小说、KMP 与构建；独立 Standards 与 Spec 审查。
2. 候选二次复核，失败测试或可观测复现，确定修复分组。
3. 按依赖实施修复，每阶段测试后独立审查并收口。
4. 集成验证、一次有限可维护性检查，输出问题与结果。

状态：本轮确认的 37 项问题已修复，七阶段独立 review 与最后的有限可维护性检查已收口。Home v2 与 Search 真实 UI 已完成；Novel 1057 通过/2 跳过，DeepRead 109/109 通过；MCP-1 的 Client/Manager 51/51 通过。主 App 历次失败均保留实际结果：最后一次完整运行 5144 项，5135 通过、1 失败、8 跳过；唯一失败为 Quick Start fixture 提前接受建议，修正 readiness 后整组 8/8 通过，独立复核 PASS，生产源码未变。MCP FIFO 与 KeepAlive 固定等待误报也已分别修正并复核；无收益的表格实验已撤回，后两轮完整组合中的原始性能门禁均通过。收尾按“完整组合＋最后受影响整组”交付，未将失败整轮改写为绿色，未因测试修正再重复整轮。清单见 [findings.md](findings.md)，实际证据见 [verification.md](verification.md)。

证据目录：`/tmp/amber-audit-20261018-current`；修改前文件 SHA256、Git status 与完整 tracked WIP patch。
