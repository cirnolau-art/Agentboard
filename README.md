# AgentBoard

在 Apple Silicon Mac 上显示 CC Switch token 用量、所选 API 账号余额和 AI agent 任务状态。

**Lau Kachun · v0.3.0（构建 3）**  
© 2026 Lau Kachun. All rights reserved.

版本、构建号与版权统一维护在 `Config/Version.json`，主应用与小组件一起更新。设置底部及“关于 AgentBoard”可查看完整信息。

## 使用

从源码运行 `./build-app.sh` 构建后，打开 `dist/AgentBoard.app`。菜单栏出现堆叠图标，浮窗默认显示在屏幕右侧。

- 点击菜单栏图标查看概览，右键打开设置。
- 浮窗菜单中可以隐藏浮窗、切换迷你模式或退出。
- 迷你模式默认为直径 48 点的小圆环（窗口含阴影留白为 56×56 点），可选择 40／48／56 点或小胶囊。右键可切换当前任务数、今日 token、估算费用、所选 API 余额或费用与余额组合；也可在设置 → 展示 → 迷你圆环中调整，并指定余额账号。
- 鼠标悬停约 0.25 秒显示详情，移入详情可继续操作，离开后约 0.35 秒收起。拖动圆环移动，双击恢复完整浮窗；两种模式分别记住位置，完整浮窗保留尺寸。
- 拖动窗口背景移动位置；拖动窗口边缘改变大小。窄窗口单列、宽窗口双列，高度不足时滚动。
- 设置 → API 账号，勾选需要展示的账号，直接编辑名称可设置别名。
- 设置 → Agents，选择监控工具并指定其数据目录。
- 桌面右键 → 编辑小组件 → 搜索 AgentBoard，选择小、中、大尺寸。右键组件编辑主题、账号和 agent。小组件的刷新由 macOS 调度，不适用于秒级监控。

## v0.3 功能

- 设置 → 连接状态：查看分类诊断、检测时间和最近成功时间，可立即重试或导出脱敏诊断。
- 设置 → 统计：查看今日、近 7 天、本月的 token、缓存、请求数与估算费用，按 API 筛选，按 API 或模型分组。历史账号即使已删除也可筛选。原始日志和日汇总重叠时不重复累加。
- 任务卡片区分会话累计 token 与有明确 session_id 关联的 CC Switch 记录。来源不能确认关联时不推算单次任务费用。
- 设置 → 提醒：自主启用任务完成、失败、等待确认及各 API 低余额通知，可设置静音时段和提示音。默认关闭；启用时才请求 macOS 授权。同一轮次同一状态去重，静音结束不补发积压提醒。
- 设置 → 展示：迷你圆环可多选轮播指标、设置轮播间隔和动画；悬停详情时暂停轮播。Codex 会话支持跳转，其他来源可打开项目／数据目录。
- 首次引导自动发现 agent 数据，可选择专注、费用或总览预设。设置底部可重新打开引导、应用预设、导入／导出配置；导入前自动备份并提供恢复。
- 设置 → 展示 → 主题颜色：五套预设与强调、背景、卡片、文字、辅助文字五种自定义颜色，支持系统颜色选择器和 HEX，实时应用到界面，小组件随下次刷新同步。

配置导出不含密钥、自定义 API 接口或本机路径；导入保留本机账号接口、路径、通知开关和浮窗显示状态。脱敏诊断只包含版本、系统、来源分类、时间与计数。系统通知是否显示横幅取决于系统授权及专注模式。

## 接入情况

| 数据源 | 实现方式 | 限制 |
|---|---|---|
| CC Switch | 只读 SQLite，今日输入、输出、缓存与费用 | 仅包含 CC Switch 已记录的请求；按本机时区划分今日 |
| API 余额 | 识别启用的 sub2api 模板、DeepSeek 官方接口；自定义 HTTPS GET JSON；手动余额 | 不执行供应商配置中的任意脚本；其他模板需要自定义接口 |
| Codex | 自动发现 `state_*.sqlite` 与 `thread_history_*.sqlite`，结合最新轮次及明确开始／结束事件 | 暂时占用时自动重试，30 秒内标注并保留上次结果；结构出现根本变化时仍可能需要适配 |
| WorkBuddy | `workbuddy.db` 会话状态 | 依赖会话状态字段的更新 |
| DeepSeek Harness | 解码 `session.v4.jsonl.zstd` 中的 turn/start、turn/end | 使用本机 `/opt/homebrew/bin/zstd` 或 `/usr/local/bin/zstd` |
| Qwen Code | 官方 ChatRecord JSONL 的 turn_attempt、turn_result 与标题事件；兼容旧版 JSON 会话 | 本机未安装，使用格式样本验证；旧格式缺少结束事件时显示未知 |
| Claude Code | 会话活动 + 通用事件接入 | 单凭 assistant 消息无法确认任务完成，需事件接入获得精确状态 |
| 其他 agent | 通用 JSON 事件文件 | 由外部工具或 hooks 写入 |

API 余额不与估算费用混算。不同币种、积分或额度分别展示。查询失败保留上次成功结果并标记错误和更新时间。运行状态超过 10 分钟没有更新时标记为待确认，不把静默当作完成。

Codex 轮次数据库短暂被占用、缺失或投影延迟时，使用会话 JSONL 中的 `task_started`、`task_complete`、`turn_aborted` 事件补充状态。普通 assistant 消息不能证明任务结束。会话主数据库短暂忙碌时显示“重试中”，超过 30 秒仍不可读则显示实际错误；恢复后下次轮询自动重连。迷你详情和完整浮窗均显示各 agent 的连接状态及失败原因，可点击重新检测。

## 通用事件接入

工具位于 `Tools/agentboard-event.py`，可以放入相应 agent 的 hooks 或任务包装脚本。AgentBoard 不修改其他工具的配置。

```sh
python3 Tools/agentboard-event.py --agent qwen --task-id example --state running --title '整理项目'
python3 Tools/agentboard-event.py --agent qwen --task-id example --state waiting --title '等待操作确认'
python3 Tools/agentboard-event.py --agent qwen --task-id example --state completed --title '整理项目'
```

默认事件目录：`~/Library/Application Support/AgentBoard/events`。同一个任务使用相同 `task-id`，状态变化时原子替换文件。AgentBoard 支持如下 JSON，也支持每行一条的 JSONL：

```json
{"schema":"agentboard.v1","agent":"qwen","taskId":"example","title":"整理项目","project":"/path/to/project","state":"running","updatedAt":"2026-11-10T05:00:00Z"}
```

可用状态：`running`、`waiting`、`completed`、`failed`、`interrupted`、`idle`、`unknown`。

## 构建与检查

需要完整 Xcode，最低 macOS 14，本项目默认构建 arm64。无第三方 Swift 包。

```sh
./build-app.sh
./dist/AgentBoard.app/Contents/MacOS/AgentBoard --self-test
./dist/AgentBoard.app/Contents/MacOS/AgentBoard --diagnose
./Tools/check-widget-sandbox.sh
./dist/AgentBoard.app/Contents/MacOS/AgentBoard --snapshot --snapshot-output /tmp/agentboard-snapshots
```

`--self-test` 使用隔离的临时数据库验证日期边界、账号归属、去重、状态映射、事件接入、余额解析和快照结构。`--diagnose` 仅读取真实本机数据并输出计数，不打印密钥或会话正文。截图模式读取真实数据，不发起余额网络请求。

`generate-project.py` 生成并保存 Xcode 项目，包含主应用与 WidgetKit 扩展两个 target。`build-app.sh` 默认使用本机 ad-hoc 签名。为兼容本机签名，组件通过沙盒的精确目录只读授权读取 `WidgetData`，不要求 Apple 开发者账号。组件没有访问 agent 配置或密钥的权限。正式分发时可以配置自己的签名团队、App Group 和描述文件，并用 `APP_GROUP_DISTRIBUTION` 编译条件启用 App Group。本机小组件已注册并不等同于用户已将其添加到桌面。

## 本地数据

- 设置：`~/Library/Application Support/AgentBoard/preferences.json`
- 不含密钥的组件快照：`~/Library/Application Support/AgentBoard/WidgetData/snapshot.json`
- 自定义接口密钥：macOS 钥匙串，service 为 `local.agentboard.balance`
- 不修改 CC Switch 或 agent 数据库；不需要辅助功能、屏幕录制或管理员权限。
- 关闭设置或隐藏浮窗后继续采集；从菜单选择退出后停止采集，小组件保留最后快照及时间。

余额查询仅向对应配置地址发送 HTTPS GET；不跟随重定向，不记录响应正文或凭据。共享快照只包含所选账号及展示任务，包含任务标题；小组件将任务标题标记为隐私内容。

## GitHub 与使用授权

项目上传操作见 [GITHUB_UPLOAD.md](GITHUB_UPLOAD.md)。构建产物、真实数据截图、测试日志、本机配置、数据库和凭据不纳入版本控制。

© 2026 Lau Kachun. All rights reserved. 当前未授予开源许可证；公开仓库不代表自动授予修改、再分发或商业使用许可。
