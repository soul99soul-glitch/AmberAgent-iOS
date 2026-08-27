# iOS Project Instructions

- 本目录是独立的 iOS/KMP 构建根；不得通过兄弟目录或绝对路径读取其他产品仓库。
- 原生应用在 `iosApp/`，继续遵守 `iosApp/AGENTS.md`；小说任务继续读取更深层规则。
- Swift 目前仍通过本目录的 Gradle 工程生成 `Shared.framework`。不要假装 Core 已独立发布。
- 修改 KMP provider/runtime/storage 时，同时验证 Swift 消费入口与对应 Gradle 测试。
- 只把稳定、平台无关且已有两端消费者的能力提议迁往版本化的 AmberAgent Core 制品；本仓 `core/` 仍是 iOS 过渡实现。
- 默认验证从受影响测试开始；视觉、后台、系统权限和真实 provider 仍需模拟器或真机证据。
