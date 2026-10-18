# Phase 2 MiniApp image observer 独立窄复核

结论：**PASS，无 blocking**。只读 `MiniAppRunnerWebView.swift:715–775` 最终补丁及 `IOSMiniAppDocumentLifecycleTests.testImageProxySettlesAfterInitialAndDynamicDOMChanges`；未构建、跑测试、修改源码，不扩大其他旧协议边界。

- `rewriteAttribute` 获取当前raw attribute，transform后仅在字符串变化时调用原setAttribute。已proxy的amber scheme在`proxy`不再改写；CSS替换只匹配https URL，故已改写的style文本第二次保持不变。
- STYLE textContent同样先比较；首次替换产生的childList record加入的是Text node，rewrite的nodeType guard直接略过。后续祖先扫描也因CSS相等而不再写。
- srcset现先令每个candidate等于trim结果，再匹配https URL和原descriptor suffix。首次转换保留`1x`/`2x`，逗号之间统一`, `；已proxy候选不匹配https但返回trim后的候选，第二次join得到完全相同的文本。首修“返回含原leading空格candidate再join”造成的空格增长已被精准消除。
- 测试初始同时包含src、双descriptor srcset、STYLE以及无需改写的`color:red`；动态阶段使用原生property路径更新src/srcset/inline backgroundImage，确实需要observer补写。descriptor有完整后缀断言，dynamic的目标文件名及scheme也被断言。
- 有限observer guard只在测试注入，不改变产品脚本。超过32 callbacks/64 records即置guarded并断开，初始/动态snapshot均要求guarded=false且callbacks<32；因此旧自激被guard打断以后仍然会测试失败，guard不能掩盖问题。两次setTimeout在相应microtask排空后取snapshot，waitForObject也有有限等待。

本项修复沿既有URL改写逻辑实现幂等，没有增加运行次数上限、禁用observer或延迟重试。实际green证据由Root统一提供。
