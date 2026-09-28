# perf — 发送气泡卡顿排查脚本

固化自“排查发送气泡上屏卡顿”时在 /tmp 下临时写的分析方法（Time Profiler 主线程采样
解析、按锚点函数聚类、25ms 分格时间线、区间 top N、新旧对比、间隔 gap 检测）。

## 文件

- `record.sh` — 用 `xctrace record --template 'Time Profiler'` 录制。
- `analyze.py`（仅标准库）— 解析 `.trace`，提供 `export / hangs / anchors / timeline / top / ab / gaps` 子命令。

## 典型流程

1. **录制**：`./record.sh --duration 20 --output /tmp/amber-send.trace`（真机默认进程
   `iosAppExperimentalGPL`；`--simulator <UDID>` 切模拟器，默认进程 `iosApp`）。
2. **找锚点**：`./analyze.py anchors /tmp/amber-send.trace sendComposerMessage`
   —— 第一次会自动 `xctrace export` + 解析主线程样本，缓存到
   `/tmp/amber-send.trace.mainthread.pkl`，之后的子命令直接复用，不再重新导出。
3. **看时间线**：`./analyze.py timeline /tmp/amber-send.trace <锚点秒>`
   —— 以锚点为 0，25ms 一格看主线程样本密度和标签分布。
4. **看区间热点**：`./analyze.py top /tmp/amber-send.trace <起秒> <止秒>`
   —— 该区间内 app 自身函数（`debug.dylib` / `iosApp`）包含样本 top N，
   以及最内层 app 帧 top N（更接近“时间花在哪一行”）。
5. **新旧对比**：`./analyze.py ab <旧trace> <旧锚点秒> <新trace> <新锚点秒>`
   —— 同一窗口长度下，关键函数在新旧两个 trace 里各出现多少次采样。
6. **找阻塞**：`./analyze.py gaps <trace> <锚点函数子串> <锚点秒>`
   —— 只看含锚点函数的样本之间的时间间隔，间隔明显大于一个采样周期（>3ms）
   往往意味着主线程被同步 IPC/锁阻塞而不是在跑 Swift 代码。

也可以先跑 `./analyze.py hangs <trace>` 看 Instruments 自动标出的 potential hangs，
再拿其中的起点去跑 `anchors` / `timeline` 精确定位。

## 两条判读要点

- **Debug 构建会放大 Swift CPU 成本，但不影响 IPC 阻塞**：Debug 下 ARC 保留/释放、
  协议见证表分发、`AG::Graph` 依赖图重算这些 Swift 侧开销比 Release 高不少，
  `top` 里看到的大量 app 函数采样很多是 Debug 特有的额外成本，不能直接当成
  Release 也会卡的证据；但如果 `gaps` 里发现的是等锁 / 等 XPC 回复这种阻塞
  （同一函数内长时间没有新采样、`leaf` 是 `objc_msgSend`/`swift_release` 之外的
  系统调用），这类阻塞在 Debug/Release 下都会发生，是更值得优先修的信号。
- **动画丝不丝滑，看动画窗口里每 25ms 是否接近满格采样**：Time Profiler 按约
  1ms 一次采样，`timeline` 的每个 25ms 格子理论上限接近 25 个样本。如果动画
  播放期间（比如气泡上屏、滚动）某几格样本数明显掉到个位数，说明那段时间主
  线程被别的工作抢占甚至阻塞，画面对应就是掉帧/卡顿；反之持续接近满格并不
  代表流畅（可能是在跑别的重逻辑），还要结合 `label` 分类和 `top` 看清楚这些
  样本具体落在哪些函数上。

## 已知限制

- `time-profile` XML 解析只保留 `thread.fmt` 包含 `Main Thread` 的样本，其他线程
  （网络、GC、后台队列）不在分析范围内，`gaps`/`top` 看到的都是主线程视角。
- `top`/`gaps` 判断“是否 app 函数”的规则是二进制名包含 `debug.dylib` 或等于
  `iosApp`（含前缀），systemd 库或 Kotlin/Native 生成的独立二进制不在此列，
  必要时改 `analyze.py` 里的 `is_app_binary()`。
- `ab`/`timeline` 的默认关键字/标签集是从这次排查里沿用下来的固定字符串
  （`sendComposerMessage`、`AmberMarkdownView`……），换一个问题场景基本要用
  `--keys` / `--label` 自己指定，默认值只是个起点。
- 大 trace（几十 MB 甚至上百 MB 的 XML）导出解析要几秒到几十秒；`.mainthread.pkl`
  缓存按 trace 路径命名，trace 改名或搬家后要重新 `export`。
- `record.sh` 真机分支依赖 `devicectl device info processes --json-output`
  的字段结构，不同 Xcode 版本字段名可能变化，找不到 pid 时先手动跑一遍这条
  命令核对 JSON 结构。
