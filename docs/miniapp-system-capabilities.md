# Amber MiniApp 系统能力（iOS）

MiniApp 的系统能力通过 `Amber` JavaScript SDK 暴露，当前 iOS bridge 版本为 `0.3-system-capabilities`。能力调用仍然经过 MiniApp manifest、应用设置和单独授权检查；JavaScript 只负责调用，不绕过这些检查。

## 发现能力

```js
const app = await Amber.getAppInfo();
const capabilities = await Amber.getCapabilities();
```

`getAppInfo()` 调用 `app.info`，返回当前小应用的身份、版本、声明权限和已记录授权。`getCapabilities()` 调用 `app.capabilities`，返回类似下面的对象：

```js
{
  platform: "ios",
  bridgeVersion: "0.3-system-capabilities",
  systemCapabilitiesEnabled: true,
  methods: ["haptics.impact", "device.getInfo", "screen.getBrightness"],
  permissions: [
    { permission: "haptics", declared: true, enabled: true, decision: "ALLOW" }
  ]
}
```

其中 `decision` 可以是 `"ALLOW"`、`"DENY"` 或 `null`。读取能力不会弹授权，也不会替小应用申请权限。`methods` 是当前 bridge 的实际方法目录；生成代码前应先读取它，并在调用时捕获错误。

## 系统方法

| JavaScript 方法 | 参数与默认值 | 权限 | 返回 |
| --- | --- | --- | --- |
| `Amber.haptics.impact(options)` | `style`: `light`、`medium`、`heavy`、`soft`、`rigid`，默认 `medium`；`intensity` 为 `0...1`，默认 `1` | `haptics` | `{ok: true}` |
| `Amber.haptics.notification(options)` | `type`: `success`、`warning`、`error`，默认 `success` | `haptics` | `{ok: true}` |
| `Amber.haptics.selection()` | 无 | `haptics` | `{ok: true}` |
| `Amber.device.getInfo()` | 无 | `device` | 设备信息对象 |
| `Amber.device.getBattery()` | 无 | `device` | 电池信息对象 |
| `Amber.screen.getBrightness()` | 无 | `screen` | `0...1` 数值 |
| `Amber.screen.setBrightness(value)` | `number`，或 `{brightness: 0...1}` | `screen` | `{ok: true}` |
| `Amber.screen.setKeepAwake(value)` | `boolean`，或 `{enabled: boolean}` | `screen` | `{ok: true}` |
| `Amber.speech.getVoices()` | 无 | `speech` | `[{identifier,name,language,quality,gender,voiceTraits}]` |
| `Amber.speech.speak(value)` | 字符串，或 `{text, language?, rate?, pitch?, volume?}`；文本最多 4000 字符；`rate` 范围 `0...1`、`pitch` 范围 `0.5...2`、`volume` 范围 `0...1`，默认值分别为 `0.5`、`1`、`1` | `speech` | `{speaking: true}` |
| `Amber.speech.stop()` | 无 | `speech` | `{stopped: true|false}` |
| `Amber.speech.pause()` | 无 | `speech` | `{paused: true|false}` |
| `Amber.speech.resume()` | 无 | `speech` | `{resumed: true|false}` |
| `Amber.share(options)` | `{text?, url?}`；文本最多 20000 字符 | `share` | `{completed: true|false}` |
| `Amber.openURL(value)` | URL 字符串，或 `{url}` | `openURL` | `{opened: true|false, url}` |
| `Amber.qrcode.generate(value)` | 文本字符串，或 `{text, size?}`；文本最多 1024 UTF-8 字节；`size` 为 `128...1024` 的整数，默认 `256` | 无 | `{dataURL, width, height}` |

`language`、`url` 等可选字符串以及长度、范围限制由 iOS bridge 校验；不符合契约会返回 rejected Promise。二维码不申请权限，但仍受 bridge 的输入限制。

URL 支持公开 HTTPS、`mailto:` 和 `tel:`，最多 4096 UTF-8 字节；拒绝自定义协议、URL 内凭据和明确的本地或私网地址。二维码的 `size` 是目标边长；为保留可扫描的像素和留白，输出可能略大，请以返回的 `width`、`height` 为准。

## 权限与错误处理

声明权限只是前置条件。`screen` 的亮度和常亮设置还需要在 MiniApp manifest 中声明 `screen`，并通过一次独立授权；设置关闭、manifest 未声明、用户拒绝和授权处理器不可用都会返回错误。缺少对应硬件或系统服务时也返回错误，小应用应保留可见的降级路径。

所有系统能力都应捕获 rejected Promise：

```js
async function pulse() {
  try {
    await Amber.haptics.impact({style: "light", intensity: 0.7});
    await Amber.haptics.notification({type: "success"});
    await Amber.haptics.selection();
  } catch (error) {
    // 没有触感硬件、权限未放行或系统不可用时继续页面流程。
    console.log("haptics unavailable", error);
  }
}
```

`Amber.openURL` 每次调用都会请求用户确认。`Amber.share` 只打开系统分享界面，用户需要手动选择目标，MiniApp 不会自动发送内容。

## 生命周期

这些能力属于当前 MiniApp 页面。页面退出会关闭 bridge、停止进行中的语音并释放常亮；进入后台时，相关系统活动会暂停或停止并立即恢复屏幕状态。页面回到前台后不会自动重新应用之前的屏幕设置。MiniApp 不应假设语音、常亮或待处理的系统请求能跨页面或后台持续。

当前文档只描述 iOS bridge 已实现的能力。`systemCapabilitiesEnabled` 关闭时，包括二维码生成在内的系统方法都会被拒绝；方法是否可用应以 `Amber.getCapabilities()` 为准，不要根据其它平台或未出现在目录中的方法自行推断。

## 验证记录（2026-09-08）

本轮已完成 subagent 调用链、原生生命周期和 UI review，并修复确认的问题。原工程最终构建成功：iPhone 定向回归 92 项通过、0 失败；同一构建产物的 iPad 原生能力回归 10 项通过、0 失败。UI 留有 10 张生产视图截图，覆盖窄屏、大辅助字号、中英文及全局关闭权限状态。

先前 Watch 编译阻塞已由并行任务修复，最终结果直接来自原工程。代码与模拟器审查可收口；整体 Review Convergence Gate 仍为 PARTIAL，真机触感、实际音频及真实分享/邮件/拨号目标尚未验证。

完整发现清单、修复证据、结果包及截图见 [MiniApp 审查记录](/Users/mi/Downloads/AI/AmberAgent/ios/docs/miniapp-review-2026-09-08.md)。
