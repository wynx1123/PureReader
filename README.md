# 纯享阅读 (PureReader)

零广告、零付费墙、纯享阅读体验的开源 iOS 小说阅读器。

| 项 | 值 |
|----|-----|
| 平台 | iOS 17.0+ |
| UI | SwiftUI |
| 数据 | SwiftData（**仅本地**，不做 iCloud） |
| Bundle ID | `com.wynx.PureReader` |
| 展示名 | 纯享阅读 |
| 签名 | CI 产出 **未签名 IPA**，可用全能签 / 自签安装 |

## 愿景

对标「番茄小说」核心阅读体验，但完全纯净：

- 零广告、零推广、零付费墙
- Apple 原生设计语言
- 完整暗色模式
- 沉浸式阅读（3 种翻页模式）
- 内置 TTS 听书
- 本地 TXT/EPUB + 书源

## 开发阶段

| Phase | 内容 | 状态 |
|-------|------|------|
| 1 | 脚手架 & CI/CD | ✅ |
| 2 | 书架 & 数据模型 & 导入 | ✅ |
| 3 | 阅读器引擎 + TTS | ✅ |
| 4 | 书源系统 | ✅ |
| 5 | 打磨 & 全量测试 & 交付 | 待开始 |

## 架构（MVVM）

```
Views/       → 纯 SwiftUI，无业务逻辑
ViewModels/  → @MainActor 状态编排
Services/    → 无状态服务（导入 / 分页 / 网络 / TTS）
Models/      → SwiftData @Model + 枚举
App/         → 入口与 ModelContainer
```

依赖方向：`View → ViewModel → Service → Model`

## 目录结构

```
PureReader/
├── App/PureReaderApp.swift
├── Models/
├── Views/{Bookshelf,Reader,Discovery,Stats,Settings}/
├── ViewModels/
├── Services/
├── Extensions/
├── Resources/Assets.xcassets
├── .github/workflows/build.yml
├── fastlane/Fastfile
└── scripts/generate_pbxproj.py
```

## CI 未签名 IPA

Push 到 `main` / `develop` 或手动 **Actions → Build IPA → Run workflow**。

产物 Artifact：`PureReader.ipa`（内含 `PureReader-unsigned.ipa`）。

安装：

1. 下载 `PureReader-unsigned.ipa`
2. 用 **全能签** / SideStore 等签名安装
3. 信任证书后启动

## 分支策略

- `main` — 稳定可构建
- `develop` — 日常集成
- `feature/*` — 功能分支（可选）

## 关键决策（Phase 1）

- 仓库 Public 开源
- **不做 iCloud**（纯本地 SwiftData）
- 用户侧用全能签自行签名
- 最低部署 iOS 17.0（SwiftData 硬性要求；文档原写 16 与 SwiftData 冲突，以 17 为准）

## 技能审查记录

Phase 1 使用：软件架构设计、系统架构师、GitHub同步、Git工作树

## License

MIT（待 Phase 5 最终确认）


## Phase 2 功能

- TXT / EPUB 本地导入（fileImporter）
- HTTPS 直链导入（15s 超时 + 最多 2 次重试）
- 章节解析写入 SwiftData
- 书架网格 / 列表、排序、分组、标签、搜索
- 编辑元数据、滑动删除


## Phase 3 功能

- Core Text 分页（字号/行距/边距）
- 三种翻页：左右滑动 / 仿真翻页 / 上下滚动
- 6 种背景（含纸张纹理 / 羊皮纸）
- 进度持久化 + 阅读时长统计 + 热力图
- TTS 听书（后台音频、锁屏控制、中文音色）


## AI 改写 & 向量检索（扩展）

- OpenAI 兼容 API（设置 → AI 改写与向量）
- 选中文本 AI 改写 + 风格预设 + 校验 + 历史
- 语义分块 + Embedding 向量索引（本地磁盘缓存）
- 全书记忆锚点（角色/世界观/伏笔/里程碑）
- 后台静默消化，不阻塞阅读；改写后增量更新索引

## 2026-07-22 更新

- **导入修复**：fileImporter 挂根视图 + 沙盒副本 + 宽 UTType
- **AI**：改写历史 / 单条撤销 / 一键还原 / 对比 UI / 导出 TXT / 批量整页
- **UI**：参考 Apple 图书（封面书衣、暖中性背景、大标题图书 Tab）
- **书源**：探活检测 + URL 导入合集
