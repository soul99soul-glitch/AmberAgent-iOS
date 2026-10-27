# 本轮原生组件测试容器

这些文件只用于独立临时 SwiftPM harness，均不是生产入口、生产 provider 或替身页面。生产 UI/Runtime 原封不动复制；生产文件及 SHA-256 在 `../components/source-manifest.tsv`。General 通知授权页不在裸进程运行；Editor 回调由临时 continuation 以成功/失败值控制。

实际执行目录为 `/tmp/amber-comprehensive-ui-review`，源码副本在 `Sources/AmberOffscreenReview`。重建容器时，将清单中78份生产源文件按 basename 复制到该目录，并逐个检查 SHA-256；再加入本目录三份 Swift 入口/fixture 和 Package.swift。Package 的 iosMath 路径为本项目已有 checkout，无新下载依赖。目标源文件名没有重名。

成功构建命令：

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/amber-comprehensive-ui-review/ModuleCache CLANG_MODULE_CACHE_PATH=/tmp/amber-comprehensive-ui-review/ClangModuleCache swift build --package-path /tmp/amber-comprehensive-ui-review --disable-sandbox -j 2 -Xswiftc -Xfrontend -Xswiftc -disable-sandbox
```

成功状态运行命令：

```sh
AMBER_OFFSCREEN_FILTER=phase2 /tmp/amber-comprehensive-ui-review/.build/debug/AmberOffscreenReview
AMBER_OFFSCREEN_FILTER=phase3-editor /tmp/amber-comprehensive-ui-review/.build/debug/AmberOffscreenReview
```

`AMBER_OFFSCREEN_FILTER` 只过滤截图；公共基线 fixture 和生图恢复模型断言仍运行。输出路径固定为本项目 `ui-after/components`，重跑会覆盖对应 PNG。

`after-build.log`、`phase2-states.log`、`phase3-editor-states.log` 均来自最终成功轮次，构建及两轮运行 exit0。日志中系统 LaunchServices/XPC 警告不等同生产崩溃；全部实际断言完成。

Editor 使用真实 SwiftUI `.sheet`，通过测试进程自身的 `NSWindow.performKeyEquivalent(with:)` 向真实按钮发送 ⌘Return/Escape；不向用户 App 注入系统事件。NSApp 当前原生 sheet 使用独立窗口（`attachedSheet == nil`），因此成功关闭验证使用呈现 binding 与实际窗口可见性，而不假定窗口实现。busy 阶段正文离屏绘制差异见 `../review.md`，不改生产来迎合测试。
