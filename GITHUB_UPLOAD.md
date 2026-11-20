# AgentBoard GitHub 上传说明

作者：**Lau Kachun**  
当前版本：**v0.3.0（构建 3）**  
© 2026 Lau Kachun. All rights reserved.

## 项目位置

本机项目已经迁移到 `/Users/kachunlau/Documents/GitHub/Agentboard`，保留该目录已有的 Git 仓库。项目介绍与完整使用说明见 [README.md](README.md)。

## 仓库简介

AgentBoard 是 Apple Silicon Mac 上的原生 AI 工作台，通过菜单栏、可调尺寸浮窗、迷你圆环和小／中／大桌面小组件，查看 CC Switch token 用量、所选 API 余额及 Codex 等 AI agent 的任务状态。支持用量趋势、状态诊断、任务与低余额提醒、自定义主题颜色以及配置导入导出。

可填写到 GitHub 仓库 Description：

> Native macOS dashboard for AI agent tasks, CC Switch token usage and API balances, with menu bar, floating ring, widgets and custom themes.

## 用 GitHub Desktop 上传

1. 在 GitHub Desktop 中选择 File → Add Local Repository，选择上述项目目录。
2. 在 Changes 中检查文件列表。正常应包含 App、Shared、Widget、Config、Tools、Xcode 项目、构建脚本及 Markdown 文档。
3. 确认不包含个人 API Key、账号配置、数据库、任务截图或日志，然后填写提交说明并提交，例如 `Add AgentBoard v0.3.0`。
4. 若仓库尚未发布，点击 Publish repository，选择名称与公开／私有可见性；若已关联远程，点击 Push origin。

## 用命令行上传

先检查并提交本地文件：

```sh
cd /Users/kachunlau/Documents/GitHub/Agentboard
git status --short
git add .
git diff --cached --stat
git commit -m "Add AgentBoard v0.3.0"
```

查看是否已配置远程与当前分支：

```sh
git remote -v
git branch --show-current
```

若已有正确的 origin，使用 `git push -u origin HEAD`。若尚无远程，先在 GitHub 新建空仓库，再执行以下命令，将占位地址换成实际仓库地址：

```sh
git remote add origin https://github.com/YOUR_USERNAME/Agentboard.git
git push -u origin HEAD
```

## 构建与运行

要求 Apple Silicon Mac、macOS 14 或更新系统、完整 Xcode 与 Python 3，无第三方 Swift 包。

```sh
./build-app.sh
open dist/AgentBoard.app
```

主应用与 WidgetKit 扩展默认采用本机 ad-hoc 签名。将 `.app` 发布给其他用户前，需要另外处理 Developer ID 签名与公证；当前本机构建不等同于已公证的分发安装包。

## 上传范围与隐私

- `.gitignore` 排除 `build/`、`dist/`、`artifacts/`、Xcode 个人状态、常见数据库及凭据文件。
- `artifacts/` 内可能包含真实任务名称和统计截图，因此整目录不上传。
- 运行时设置、通知记录和组件快照保存在用户的 Application Support 目录，自定义接口密钥保存在钥匙串，均不属于项目源码。
- 不要手动将真实配置导出或诊断报告添加到仓库；即使没有密钥，也可能包含个人偏好与用量信息。
- 当前保留作者版权，未添加 MIT、Apache 等开源许可证。需要开源授权时，应由作者另行选择许可证。

## 发布版本

版本与版权统一维护在 `Config/Version.json`。更新版本后重新运行 `./build-app.sh`，主应用和小组件版本会同步。若需要发布 Release，可在确认分发签名方案后单独上传安装包，不要把生成的 `.app` 加进源码提交。
