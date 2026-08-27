# AmberAgent for iOS

AmberAgent 的 iOS 产品仓库。SwiftUI App、iOS KMP 过渡模块、Native 组件和项目生成配置都在本仓维护；Android 产品代码不再混放。

## 生成与构建

```bash
cd iosApp
xcodegen generate
cd ..
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64
xcodebuild -project iosApp/AmberAgent.xcodeproj -scheme iosApp -showdestinations
```

`iosApp/project.yml` 是 Xcode 工程事实来源；生成的 `.xcodeproj` 不提交。Core 的正式版本化制品发布前，现有过渡 KMP 实现保持在本仓，不做跨仓相对路径依赖。
