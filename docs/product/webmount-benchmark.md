# iOS WebMount 基准任务清单

日期：2026-09-25。用途：阶段 0 的手工/真机复测；不接入 CI。

共 18 项：只读 5 项、表单与控件 4 项、翻页/滚动取数 4 项、Canvas 3 项、需登录 2 项。

## 复测约定

- 每项任务使用新的 WebMount 会话，按表中的目标原文执行。复测时保持设备、App 构建、模型/provider 和权限设置一致；页面内容会变化的任务按本次页面快照判定，不比较固定答案。
- **一轮**按 Agent 发出的一个 `wm_*` 工具调用计数；重复调用分别计数，`wm_act` 按一次调用计数。用户审批、用户接管和登录不计入 Agent 轮数，但记入运行报告的交还用户次数；墙钟时间包含等待时间。
- 运行后记录任务编号、通过/失败/受环境阻塞、总工具调用、`wm_*` 调用、失败/拒绝、交还用户次数和墙钟时长。受 DNS、站点可用性或当前权限策略阻塞时记为“受环境阻塞”，不要改变 allowlist 或绕过安全策略。
- 表单只使用本清单标出的测试页面和虚构数据；每次提交仍按 App 现有审批流程执行。登录任务由用户在 WebMount 页面内手动完成；Agent 不输入、读取或复述密码、验证码或其他凭据。
- 登录任务从目标站点的未登录页开始；若站点已有登录态，记为“受环境阻塞”，不要自动清除站点数据。
- Canvas 任务以当前视口截图为判据；`wm_visual_read` 需要现有审批且视觉能力可用。未获得截图或视觉读取不可用时记为“受环境阻塞”，不要仅凭 DOM 代码或页面描述声称看到了图表。

## 任务

### 只读

| ID | 站点 | 目标 | 完成判据 | 期望最大轮数 |
|---|---|---|---|---:|
| R1 | [RFC 9110 §15](https://www.rfc-editor.org/rfc/rfc9110.html#section-15) | 找到 404 与 500 状态码条目，并用一句话说明两者分别表示什么。 | 回答包含页面中的两个状态码标题及其含义；区分客户端错误与服务器错误。 | 4 |
| R2 | [Wikipedia：HTTP 404](https://en.wikipedia.org/wiki/HTTP_404) | 读取页面导语，说明 404 的含义及它出现在哪类响应中。 | 说明与页面导语一致，包含状态码 404；不把它误说成服务器错误。 | 4 |
| R3 | [MDN：HTTP request methods](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Methods) | 从安全性/幂等性表中读取 GET、HEAD、PUT、POST 的两项属性。 | 四种方法各自的 safe、idempotent 值均与页面表格一致。 | 5 |
| R4 | [Hacker News 首页](https://news.ycombinator.com/) | 列出当前首页前五条故事的标题及页面显示的分数，保持原顺序。 | 五条都来自同一页面快照，顺序一致；未显示分数的项目明确标为未显示。 | 4 |
| R5 | [The Internet：Data Tables](https://the-internet.herokuapp.com/tables) | 在 Example 1 中找到 Last Name 为 Bach 的行，读取该行的名字、邮箱和到期金额。 | 三个字段均来自 Bach 所在的同一行，金额保留页面格式。 | 4 |

### 表单与控件

| ID | 站点 | 目标 | 完成判据 | 期望最大轮数 |
|---|---|---|---|---:|
| F1 | [Selenium Web Form](https://www.selenium.dev/selenium/web/web-form.html) | 在 `my-text` 中填写 `webmount-stage0`，下拉框选择 `Two`，提交表单。 | 提交前读回文本和所选项均正确；提交后到达 `submitted-form.html`，页面显示 `Form submitted` 和 `Received!`。 | 8 |
| F2 | [Test Pages：HTML Form](https://testpages.eviltester.com/pages/forms/html-form/) | 填写 Username 为 `wm-stage0`、评论为 `benchmark form`，勾选 Checkbox 1 后提交；密码留空。 | 结果页能看到提交的 Username、评论和 Checkbox 1；未输入密码或个人信息。 | 9 |
| F3 | [The Internet：Inputs](https://the-internet.herokuapp.com/inputs) | 在数字输入框中输入 `42`，然后读取当前值。 | `wm_get` 返回的可见值为 `42`；不触发额外提交或导航。 | 5 |
| F4 | [The Internet：Checkboxes](https://the-internet.herokuapp.com/checkboxes) | 只将第一个复选框设为选中，并检查其状态。 | 第一个复选框的 checked 状态为 true；第二个复选框未被本次任务改变。 | 5 |

### 翻页与滚动取数

| ID | 站点 | 目标 | 完成判据 | 期望最大轮数 |
|---|---|---|---|---:|
| P1 | [Hacker News 首页](https://news.ycombinator.com/) | 记录首页前三条标题，点击 `More` 到下一页，再记录该页前三条标题。 | 第二页 URL 含 `p=2`；两页各有三条、顺序正确，并明确标出两页间是否有重复标题。 | 8 |
| P2 | [Books to Scrape：Mystery](https://books.toscrape.com/catalogue/category/books/mystery_3/index.html) | 读取第一页前三本书的标题和价格，点击 `next`，读取第二页前三本书。 | 第二页 URL 为该目录的 `page-2.html`；各页标题/价格对应同一商品，第二页不是第一页的重复内容。 | 9 |
| P3 | [Quotes to Scrape](https://quotes.toscrape.com/) | 读取第一页第一条引言及作者，点击 `Next` 后读取第二页第一条引言及作者。 | 第二页 URL 含 `/page/2/`；两组引言与作者均匹配各自页面，能指出页面已翻页。 | 8 |
| P4 | [The Internet：Infinite Scroll](https://the-internet.herokuapp.com/infinite_scroll) | 先记录当前可见的一段正文，向下滚动一次，读取新加载内容的首段。 | 滚动后可见至少一段初始视口没有的正文，并给出该段开头；最多滚动两次后停止。 | 9 |

### Canvas

| ID | 站点 | 目标 | 完成判据 | 期望最大轮数 |
|---|---|---|---|---:|
| C1 | [Chart.js：Line Chart sample](https://www.chartjs.org/docs/latest/samples/line/line.html) | 根据当前画面报告图表标题、可见系列名称，以及横轴首尾标签。 | 截图中确实显示 canvas 图表；标题、系列名称与横轴首尾标签都和画面一致。随机数据值不作为固定答案。 | 6 |
| C2 | [Chart.js：Stepped Line sample](https://www.chartjs.org/docs/latest/samples/line/stepped.html) | 判断画面中的线是阶梯形还是斜线连接，并读取横轴首尾标签。 | 结论与 canvas 实际绘制形状一致；能报告首尾标签，不从示例源码推断绘图结果。 | 6 |
| C3 | [Chart.js：Scriptable Bar sample](https://www.chartjs.org/docs/latest/samples/scriptable/bar.html) | 以零基线为界，分别统计画面中零线上方和下方的柱数。 | 两个数量与截图逐柱核对一致；结果来自当前 canvas 画面。 | 6 |

### 需要登录

| ID | 站点 | 目标 | 完成判据 | 期望最大轮数 |
|---|---|---|---|---:|
| L1 | [Practice Test Automation：Test Login](https://practicetestautomation.com/practice-test-login/) | 打开登录页后交还页面给用户，由用户使用该练习站提供的测试账号登录；Agent 恢复控制后确认登录结果。 | Agent 先明确请求用户接管；恢复后 URL 含 `/logged-in-successfully/`，页面出现成功提示和 `Log out` 按钮；Agent 输出不包含凭据。 | 7 |
| L2 | [The Internet：Form Authentication](https://the-internet.herokuapp.com/login) | 打开登录页后交还页面给用户，由用户使用页面公布的练习账号登录；Agent 恢复控制后读取安全区域状态，不退出登录。 | Agent 先明确请求用户接管；恢复后页面显示 `Secure Area` 和成功提示；Agent 未输入或复述凭据，也未点击 `Logout`。 | 7 |
