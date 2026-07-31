# PureReader 在线书源与离线阅读功能开发规划

> 文档版本：1.0  
> 编写日期：2026-07-31  
> 适用分支：`develop` 及后续功能分支  
> 目标版本：PureReader 1.2～1.4  
> 平台：iOS 17.0+  
> 架构：SwiftUI + SwiftData + MVVM

---

## 1. 文档目的

本文档用于指导 PureReader 后续“书源、在线书籍、离线缓存、追更、导出和阅读增强”功能开发，明确：

- 产品目标与非目标
- 当前代码基线和已知问题
- 功能分期与开发顺序
- 数据模型和迁移策略
- 服务层、ViewModel、View 的职责边界
- 并发、缓存、错误处理和安全约束
- 测试、验收和发布标准

本文档不是单纯的功能列表。每个功能都应具备可执行的实现任务、验收标准和回滚方案。

---

## 2. 当前项目基线

### 2.1 已有能力

当前项目已经具备以下基础能力：

- TXT / EPUB / 本地文件导入
- SwiftData 本地书架和章节模型
- SwiftUI 书架、发现页、阅读页
- Legado / 爱阅记 / PureReader 书源导入
- 书源搜索、分类发现、目录解析和正文抓取
- 书源请求头解析和跨域敏感请求头隔离
- 在线书籍加入书架
- 在线书籍目录更新和新增章节识别
- 当前章、后续章节、全书的串行离线下载
- Application Support 下的章节缓存
- 书源验证、远程 JSON 导入和书源导出
- 阅读进度、未读章节和追更基础字段
- 书籍、书源、阅读记录、书签和 AI 改写数据备份
- AI 改写、语义分块、向量索引和全书理解基础能力

### 2.2 关键代码位置

| 模块 | 主要文件 |
|---|---|
| 书籍与章节模型 | `PureReader/Models/Book.swift` |
| 书源模型与解析规则 | `PureReader/Models/BookSource.swift` |
| 书源网络引擎 | `PureReader/Services/BookSourceEngine.swift` |
| 书源导入导出 | `PureReader/Services/BookSourceImporter.swift` |
| 在线缓存服务 | `PureReader/Services/OnlineLibraryService.swift` |
| 书架业务编排 | `PureReader/ViewModels/BookshelfViewModel.swift` |
| 发现页业务编排 | `PureReader/ViewModels/DiscoveryViewModel.swift` |
| 阅读页业务编排 | `PureReader/ViewModels/ReaderViewModel.swift` |
| 书源管理界面 | `PureReader/Views/Discovery/BookSourceManagerView.swift` |
| 书架界面 | `PureReader/Views/Bookshelf/BookshelfView.swift` |
| 书籍详情 | `PureReader/Views/Bookshelf/BookDetailSheet.swift` |
| 备份恢复 | `PureReader/Services/BackupService.swift`、`PureReader/Views/Settings/BackupView.swift` |
| 现有测试 | `PureReaderTests/OnlineLibraryServiceTests.swift` |

### 2.3 当前主要问题

以下问题应作为所有新功能的前置修复项：

1. 并发全书下载方法没有把缓存路径回写到 `Chapter.offlineCachePath`。
2. 已有缓存路径失效时，下载逻辑可能错误地判定为成功。
3. 新增的 `OnlineLibraryService.downloadAllChapters` 尚未接入书架 UI，实际仍主要使用 `BookshelfViewModel` 中的串行下载逻辑。
4. `example.com` 旧占位书源不会自动从已升级用户的数据库中迁移掉。
5. 书源导入去重可能把同一站点上的不同搜索规则误合并。
6. 在线书籍 TXT 导出没有优先读取离线缓存，且新导出方法当前没有接入 UI。
7. 自动检测备注和用户备注共用一个字符串字段，恢复检测时可能误删用户追加内容。
8. 多处 `try? modelContext.save()` 会吞掉持久化错误。

---

## 3. 产品目标与非目标

### 3.1 产品目标

PureReader 1.2～1.4 的在线阅读方向目标是形成完整闭环：

```text
书源导入
  → 书源健康检测
  → 多源搜索
  → 加入书架
  → 目录更新
  → 可恢复下载
  → 离线阅读
  → 完整导出
  → 自动追更
```

核心体验要求：

- 用户能够知道书源为什么失败。
- 下载任务可暂停、恢复、取消和重试。
- App 被系统终止后，下载状态不会丢失。
- 缓存文件和 SwiftData 记录始终保持一致。
- 在线书籍可以可靠地离线阅读和导出。
- 远程书源更新不会静默破坏用户配置。
- 敏感请求头不会跨域或明文泄漏。

### 3.2 非目标

当前版本暂不做：

- iCloud 数据同步
- 多设备实时同步
- 服务器端用户账户系统
- 付费内容破解或绕过站点权限
- 自动执行来源不明的 JavaScript 书源脚本
- 后台无限制批量抓取
- 未经用户确认的远程书源自动启用

---

## 4. 总体架构规划

### 4.1 分层原则

继续使用现有依赖方向：

```text
View
  ↓
ViewModel（@MainActor）
  ↓
Service / Manager
  ↓
SwiftData Model / 文件系统 / URLSession
```

职责要求：

- `View` 只负责展示状态和发出用户意图。
- `ViewModel` 负责页面状态、任务启动、错误呈现和 ModelContext 保存协调。
- `Service` 负责网络、文件、解析、序列化等可测试逻辑。
- `Manager` 负责跨页面、可持续运行的任务，例如下载队列和书源健康记录。
- SwiftData 模型只保存业务状态，不保存临时 UI 状态。

### 4.2 推荐新增组件

| 组件 | 类型 | 责任 |
|---|---|---|
| `DownloadManager` | `@MainActor` 单例或环境对象 | 管理下载队列、暂停、取消、恢复、重试 |
| `CacheIntegrityService` | 无状态 Service | 检查缓存路径、文件大小、内容有效性和孤立文件 |
| `BookSourceHealthService` | 无状态 Service | 执行快速/完整检测，返回结构化检测报告 |
| `BookSourceRankingService` | 无状态 Service | 根据历史成功率、延迟和用户权重计算排序 |
| `BookExportService` | 无状态 Service | TXT、Markdown、HTML、EPUB 导出 |
| `BookSourceUpdateService` | 无状态 Service | 远程书源集合版本检查、差异计算和安全更新 |
| `SearchCoordinator` | `@MainActor` 或 actor | 多源搜索、超时、结果去重、失败汇总 |

---

## 5. 开发分期总览

| 阶段 | 主题 | 目标版本 | 优先级 | 预计工作量 |
|---|---|---:|---:|---:|
| Phase 0 | 稳定性修复与基线测试 | 1.2-alpha | P0 | 3～5 天 |
| Phase 1 | 下载任务中心与缓存完整性 | 1.2 | P0 | 7～10 天 |
| Phase 2 | 书源健康中心与自动评分 | 1.2 | P1 | 6～8 天 |
| Phase 3 | 多源搜索、追更与远程源更新 | 1.3 | P1 | 8～12 天 |
| Phase 4 | 导出、全文搜索和阅读标注 | 1.3 | P1 | 8～12 天 |
| Phase 5 | AI 阅读辅助与智能书架 | 1.4 | P2 | 10～15 天 |

工作量按一名熟悉 SwiftUI/SwiftData 的开发者估算，不包含 App Store 审核时间。

---

# 6. Phase 0：稳定性修复与基线测试

## 6.1 目标

先修复当前审查发现的高风险问题，建立后续功能依赖的稳定基础。

## 6.2 任务清单

### P0-01 修复并发下载缓存回写

**涉及文件：**

- `PureReader/Services/OnlineLibraryService.swift`
- `PureReader/ViewModels/BookshelfViewModel.swift`
- `PureReader/Models/Book.swift`

要求：

- 下载任务只在后台任务中抓取和写文件。
- `Chapter.offlineCachePath`、`offlineCachedAt` 由主 Actor 统一回写。
- 回写成功后保存 SwiftData。
- 保存失败时保留下载文件，并将任务标记为“待同步”，下次启动修复。

建议结果类型：

```swift
struct ChapterDownloadResult: Sendable {
    let chapterID: UUID
    let success: Bool
    let cachePath: String?
    let byteCount: Int
    let errorMessage: String?
}
```

### P0-02 修复失效缓存误判

缓存命中条件必须同时满足：

- `offlineCachePath` 非空
- 文件存在
- 文件可读取
- 文件大小大于 0
- UTF-8 解码后正文非空
- 文件大小不超过 `maximumChapterBytes`

不满足时：

1. 清理失效路径。
2. 将章节标记为待下载。
3. 重新抓取正文。

### P0-03 统一下载入口

目前书架下载逻辑存在两套实现。应选择一套作为唯一入口：

```text
BookshelfView / BookDetailSheet
  → BookshelfViewModel.startDownload
  → DownloadManager.enqueue
  → OnlineLibraryService.fetch/write
```

`OnlineLibraryService.downloadAllChapters` 不应同时承担任务调度和 UI 状态管理。建议将它改为底层批量执行器，任务状态交给 `DownloadManager`。

### P0-04 旧占位源迁移

升级时执行一次幂等迁移：

- 删除明确匹配 `example.com` 的旧占位源。
- 按稳定内置 key 补充缺少的内置源。
- 保留用户导入的其他源。
- 迁移重复执行不会产生重复数据。

建议增加：

```swift
var builtInKey: String?
```

如果暂时不能变更模型，可使用受控 URL + 名称组合识别，但长期仍建议增加稳定字段。

### P0-05 修正书源导入身份

普通书源的身份至少由以下内容组成：

```text
format + normalizedBookURL + normalizedSearchURL + rulesDigest
```

同站点不同规则不能仅凭 `bookURL` 合并。

### P0-06 自动检测备注与用户备注分离

推荐新增：

```swift
var validationMessage: String?
var validationUpdatedAt: Date?
```

`comment` 只保存用户备注。UI 分别显示：

```text
用户备注
检测结果
```

迁移旧数据时，可以把已有“检测未通过：...”文本提取到 `validationMessage`。

## 6.3 Phase 0 验收标准

- 所有已缓存章节均能在阅读器中离线打开。
- 删除缓存后再次点击下载会真正重新下载。
- App 在下载中退出后，不会产生错误的“已完成”状态。
- 旧版本用户升级后不再看到 `example.com` 占位源。
- 导入两个同站点不同搜索规则的源后，两个源都保留。
- 检测恢复时不会删除用户备注。
- 关键保存失败会显示错误，不再静默忽略。

---

# 7. Phase 1：下载任务中心与缓存完整性

## 7.1 产品目标

将“缓存全书”从一次性串行操作升级为可靠的任务系统。

用户可执行：

- 下载当前章
- 下载后 20 章
- 下载全书
- 暂停
- 继续
- 取消
- 重试失败章节
- 仅下载缺失章节
- 检查缓存
- 清理无效缓存

## 7.2 数据模型

### 7.2.1 `Chapter` 扩展

建议新增：

```swift
enum ChapterCacheStatus: String, Codable, Sendable {
    case none
    case downloading
    case cached
    case failed
    case invalid
}
```

字段：

```swift
var cacheStatusRaw: String = "none"
var cacheErrorMessage: String?
var cacheRetryCount: Int = 0
var cacheByteCount: Int = 0
var cacheChecksum: String?
```

### 7.2.2 `DownloadTask` 模型

```swift
@Model
final class DownloadTask {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var kindRaw: String
    var statusRaw: String
    var requestedStartIndex: Int
    var requestedEndIndex: Int
    var completedCount: Int
    var failedCount: Int
    var totalCount: Int
    var createdAt: Date
    var updatedAt: Date
    var lastErrorMessage: String?
}
```

任务状态：

```swift
enum DownloadTaskStatus: String, Codable, Sendable {
    case queued
    case running
    case paused
    case cancelling
    case cancelled
    case completed
    case completedWithFailures
    case failed
}
```

### 7.2.3 `DownloadTaskItem` 模型（可选）

如果需要 App 重启后精确恢复，建议记录章节级任务：

```swift
@Model
final class DownloadTaskItem {
    @Attribute(.unique) var id: UUID
    var taskID: UUID
    var chapterID: UUID
    var statusRaw: String
    var retryCount: Int
    var errorMessage: String?
}
```

## 7.3 `DownloadManager` 接口

```swift
@MainActor
final class DownloadManager: ObservableObject {
    static let shared: DownloadManager

    @Published private(set) var tasks: [DownloadTaskSnapshot]

    func enqueue(
        book: Book,
        chapters: [Chapter],
        source: BookSourceSnapshot,
        context: ModelContext
    ) -> UUID

    func pause(taskID: UUID)
    func resume(taskID: UUID, context: ModelContext)
    func cancel(taskID: UUID, context: ModelContext)
    func retryFailed(taskID: UUID, context: ModelContext)
    func downloadMissing(bookID: UUID, context: ModelContext)
}
```

`DownloadManager` 不直接在 View 中创建大量 `Task`。所有任务必须经过统一入口，避免一个书籍同时启动多个互相覆盖的下载任务。

## 7.4 并发策略

默认并发数：3。

规则：

- 同一本书最多一个运行中的下载任务。
- 同一书源最多 3 个并发请求。
- 发现验证码/挑战时，暂停该书源相关任务。
- 收到 `429`、`503` 时执行指数退避。
- 用户取消时必须取消所有子任务，并清理未提交的临时文件。
- 每完成一个章节就持久化任务进度，避免 App 退出丢失大量进度。

建议退避时间：

```text
第 1 次：0.5 秒
第 2 次：1 秒
第 3 次：2 秒
最多：8 秒
```

## 7.5 缓存目录规划

现有目录：

```text
Application Support/
└── OfflineChapters/
    └── <bookUUID>/
        └── <chapterUUID>.txt
```

建议增加清单：

```text
Application Support/
└── OfflineChapters/
    ├── manifest.json
    └── <bookUUID>/
        └── <chapterUUID>.txt
```

清单记录：

```swift
struct CacheManifestEntry: Codable, Sendable {
    let bookID: UUID
    let chapterID: UUID
    let relativePath: String
    let byteCount: Int
    let cachedAt: Date
    let checksum: String?
}
```

## 7.6 缓存完整性检查

新增：

```swift
struct CacheIntegrityReport: Sendable {
    let totalChapters: Int
    let validCount: Int
    let missingCount: Int
    let invalidCount: Int
    let orphanFileCount: Int
    let totalBytes: Int64
}
```

检查流程：

1. 从 SwiftData 读取所有章节缓存引用。
2. 验证路径是否位于 `Application Support` 目录内。
3. 验证文件存在和大小。
4. 必要时读取正文并检查是否为空。
5. 扫描缓存目录，找出没有数据库引用的孤立文件。
6. 生成报告。

## 7.7 Phase 1 验收标准

- 下载任务能够暂停、恢复、取消和重试。
- App 重启后能恢复未完成任务状态。
- 任务只下载缺失或损坏章节。
- 同一本书不会同时存在两个运行中的全书下载任务。
- 3 个并发请求不会导致章节顺序错乱。
- 缓存文件和数据库引用一致。
- “清理无效缓存”不会删除其他书籍文件。
- 进度显示同时区分成功、失败和跳过缓存章节。

---

# 8. Phase 2：书源健康中心与自动评分

## 8.1 检测等级

### 快速检测

```text
构造搜索请求
  → 发起请求
  → 检测 HTTP 状态
  → 解析搜索结果
```

### 完整检测

```text
搜索
  → 详情页
  → 目录
  → 第一章正文
  → 内容非空且不是验证码页面
```

### 检测结果模型

```swift
struct BookSourceHealthReport: Sendable {
    let sourceID: UUID
    let checkedAt: Date
    let search: CheckResult
    let detail: CheckResult
    let catalog: CheckResult
    let content: CheckResult
    let totalDurationMilliseconds: Int
    let recommendedAction: HealthAction
}

struct CheckResult: Sendable {
    let status: CheckStatus
    let durationMilliseconds: Int
    let message: String?
}

enum CheckStatus: String, Codable, Sendable {
    case notRun
    case passed
    case failed
    case verificationRequired
    case rateLimited
    case unsupported
}
```

## 8.2 数据模型扩展

建议给 `BookSource` 增加：

```swift
var lastHealthReportJSON: String?
var lastValidationMessage: String?
var validationFailureCount: Int = 0
var searchSuccessCount: Int = 0
var searchFailureCount: Int = 0
var contentSuccessCount: Int = 0
var contentFailureCount: Int = 0
var averageLatencyMilliseconds: Int = 0
var builtInKey: String?
```

如果不希望模型字段过多，可以把检测历史放到单独的 `BookSourceHealthRecord` 模型中，只在 `BookSource` 上保存汇总字段。

## 8.3 健康中心 UI

页面分区：

1. 总览
   - 可用源数量
   - 需要验证的源数量
   - 最近失败数量
2. 书源列表
   - 状态颜色
   - 最近检测时间
   - 延迟
   - 成功率
3. 书源详情
   - 四步检测结果
   - 最近错误
   - 手动检测按钮
   - 打开验证页
4. 批量操作
   - 检测全部
   - 仅检测失败源
   - 重置统计

## 8.4 自动评分

评分输入：

- 搜索成功率：40%
- 正文成功率：30%
- 平均延迟：15%
- 最近 7 天可用性：10%
- 用户权重：5%

评分结果只用于排序，不改变用户显式启用状态。

当连续失败达到阈值时：

```text
连续失败 3 次：降低排序
连续失败 5 次：提示用户
连续失败 8 次：建议停用，但不自动停用
```

## 8.5 Phase 2 验收标准

- 快速检测和完整检测结果分开显示。
- 检测失败能明确区分网络、HTTP、验证码、解析和内容为空。
- 检测不会覆盖用户备注。
- 批量检测不会阻塞 UI。
- 书源排序结果稳定，不会因 TaskGroup 完成顺序随机变化。
- 自动评分不会暗中修改用户启用状态。

---

# 9. Phase 3：多源搜索、追更与远程书源更新

## 9.1 多源搜索协调器

新增 `SearchCoordinator`，统一处理：

- 并发数量上限
- 单源超时
- 结果收集
- 结果去重
- 来源合并
- 失败汇总
- 高分源优先

建议结果模型：

```swift
struct SearchSessionReport: Sendable {
    let query: String
    let resultCount: Int
    let attemptedSourceCount: Int
    let succeededSourceCount: Int
    let failedSourceCount: Int
    let results: [MergedSearchResult]
    let failures: [BookSourceSearchFailure]
}

struct MergedSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    let intro: String
    let coverURL: String?
    let candidates: [SourceCandidate]
}
```

去重优先级：

1. 标准化书名 + 作者
2. 同源书籍 URL
3. 站点域名 + 书籍路径

不要仅以书名去重，否则同名不同书会被错误合并。

## 9.2 追更中心

已有字段：

- `updateTrackingEnabled`
- `lastUpdateCheckedAt`
- `unreadChapterCount`
- `firstUnreadChapterIndex`
- `highestReadChapterIndex`

建议新增：

```swift
var lastUpdateErrorMessage: String?
var updateFailureCount: Int = 0
var lastKnownChapterCount: Int = 0
```

追更策略：

- 默认只检查用户开启追更的在线书籍。
- 手动检查时立即执行。
- 自动检查默认只在 Wi-Fi 下执行。
- 单次自动检查最多处理 10 本书。
- 每本书间隔至少 1 秒，避免集中请求同一站点。
- 失败不清空已有目录。

## 9.3 远程书源合集更新

远程合集格式建议：

```json
{
  "schemaVersion": 1,
  "collectionID": "purereader-verified-sources",
  "version": 12,
  "updatedAt": "2026-07-31T00:00:00Z",
  "sources": []
}
```

更新策略：

- 先下载并校验格式。
- 显示新增、修改、删除列表。
- 默认不覆盖用户备注、启用状态和请求凭据。
- 新增源默认启用状态取远程配置，但建议首次安装为关闭并提示检测。
- 删除远程源不立即删除本地源，只标记为“远程已移除”。
- 支持恢复上一次远程合集版本。

## 9.4 Phase 3 验收标准

- 多源搜索结果不重复、不随机跳动。
- 某个源失败不会阻塞其他源结果展示。
- 用户可以看到失败源数量和失败原因。
- 追更失败不会破坏已有章节。
- 远程书源更新前可预览差异。
- 用户编辑过的备注、启用状态不会被远程更新覆盖。

---

# 10. Phase 4：导出、全文搜索和阅读标注

## 10.1 统一导出服务

新增：

```swift
enum BookExportFormat: String, CaseIterable, Sendable {
    case txt
    case markdown
    case html
    case epub
}

struct BookExportOptions: Sendable {
    let includeCover: Bool
    let includeMetadata: Bool
    let onlyCachedChapters: Bool
    let replaceImagePlaceholders: Bool
}
```

导出前检查：

```text
总章节：381
已有正文：370
缺失正文：11

[导出已缓存内容]
[先下载缺失章节]
[取消]
```

在线章节正文解析顺序：

1. `chapter.content` 非空时使用。
2. 否则读取 `offlineCachePath`。
3. 仍为空时记录缺失章节。
4. 根据用户选项决定跳过或终止导出。

## 10.2 全文搜索

新增本地索引服务：

```swift
struct TextSearchHit: Identifiable, Sendable {
    let id: UUID
    let chapterID: UUID
    let chapterIndex: Int
    let chapterTitle: String
    let snippet: String
    let matchRanges: [Range<Int>]
}
```

第一版可以使用内存遍历：

- 仅搜索当前书籍
- 仅搜索已存在正文
- 限制最多返回 200 条结果
- 生成前后各 80 个字符的摘要

第二版再增加持久化索引。不要在第一次上线就引入复杂全文检索数据库。

## 10.3 书签、标注和笔记

建议新增：

```swift
@Model
final class ReadingAnnotation {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var chapterID: UUID?
    var selectedText: String
    var note: String
    var colorRaw: String
    var pageOffset: Int
    var createdAt: Date
    var updatedAt: Date
}
```

验收要求：

- 标注可以从阅读页创建。
- 书签列表可跳转到原章节和位置。
- 删除书籍时级联删除标注。
- 备份和恢复包含标注。
- 标注内容不会发送到网络，除非用户明确触发 AI 功能。

## 10.4 Phase 4 验收标准

- 在线书籍能够导出已缓存正文。
- 缺失章节会在导出前明确提示。
- TXT 导出不覆盖已有文件，文件名安全且可读。
- 全文搜索不会阻塞阅读页。
- 标注、书签可以随备份恢复。

---

# 11. Phase 5：AI 阅读辅助与智能书架

## 11.1 AI 章节摘要

使用现有：

- `BookDigestPipeline`
- `BookUnderstandingCoordinator`
- `BookVectorIndex`
- `ContextAssembler`

新增用户入口：

- 阅读页“本章摘要”
- 章节列表“生成摘要”
- 书籍详情“生成全书梗概”

摘要结构：

```swift
struct ChapterSummary: Codable, Sendable {
    let chapterID: UUID
    let summary: String
    let characters: [String]
    let events: [String]
    let foreshadowing: [String]
    let generatedAt: Date
}
```

要求：

- 默认只发送用户明确选择的章节内容。
- 生成过程中不阻塞阅读。
- 失败可重试。
- 结果缓存到本地。
- 用户可以删除 AI 生成内容。

## 11.2 AI 阅读问答

上下文范围必须显式显示：

```text
当前上下文：第 128 章
```

支持范围：

- 当前段落
- 当前章节
- 选定章节
- 整本书的已索引内容

所有会产生网络请求的入口需要显示：

- 使用的上下文范围
- 是否包含用户标注
- 是否发送到远程模型
- 当前模型配置

## 11.3 AI 书架整理

支持自然语言生成“建议操作”，但不能直接修改数据。

流程：

```text
用户请求
  → AI 解析意图
  → 生成待执行操作列表
  → 用户预览
  → 用户确认
  → ViewModel 执行
  → 保存并显示结果
```

示例操作：

```swift
enum ShelfOperation: Sendable {
    case moveBooks(bookIDs: [UUID], group: String?)
    case addTag(bookIDs: [UUID], tag: String)
    case removeTag(bookIDs: [UUID], tag: String)
}
```

---

# 12. 数据迁移策略

## 12.1 SwiftData 迁移原则

- 所有新增字段必须有默认值或可选值。
- 不直接删除已有字段。
- 枚举存 raw value，不依赖枚举顺序。
- 迁移必须幂等。
- 迁移失败时保留原数据，不执行破坏性清理。
- 重大模型变化先增加新字段，再在后续版本移除旧字段。

## 12.2 迁移版本建议

| 版本 | 迁移内容 |
|---|---|
| 1.2 | 章节缓存状态、下载任务、书源稳定 key、检测结果字段 |
| 1.3 | 标注、全文索引元数据、导出记录 |
| 1.4 | 摘要、AI 问答记录、书架操作记录 |

## 12.3 启动迁移流程

```text
App 启动
  → 检查模型容器
  → 执行 SwiftData schema migration
  → 执行业务数据迁移
  → 扫描缓存一致性
  → 恢复可恢复下载任务
  → 进入主界面
```

业务迁移错误应进入日志并显示非阻塞提示，不应让 App 无法进入书架。

---

# 13. 网络与安全要求

## 13.1 请求约束

所有书源网络请求必须：

- 只接受 HTTP/HTTPS。
- 限制单次响应大小。
- 限制连接和资源超时。
- 限制重试次数。
- 识别验证码、Cloudflare 和挑战页。
- 记录 HTTP 状态和失败类型。
- 跨域请求移除敏感 header。

## 13.2 请求头安全

敏感 header 包括：

```text
Authorization
Cookie
Set-Cookie
X-API-Key
X-Auth-Token
X-Access-Token
*-Token
*-Secret
```

后续建议：

- 敏感值使用 Keychain 保存。
- 导出书源时默认移除敏感值。
- 详情页默认隐藏敏感值。
- HTTP 请求不得发送敏感 header。
- 重定向到不同 origin 时重新剥离敏感 header。

## 13.3 文件路径安全

所有缓存路径必须：

- 以相对路径保存。
- 通过统一 `cacheURL(relativePath:)` 解析。
- 标准化后确认仍位于 Application Support 内。
- 禁止 `..` 穿越。
- 不使用用户输入直接作为文件名。

---

# 14. 测试规划

## 14.1 单元测试

新增测试文件建议：

```text
PureReaderTests/
├── OnlineLibraryServiceTests.swift
├── BookSourceImporterTests.swift
├── BookSourceEngineTests.swift
├── DownloadManagerTests.swift
├── CacheIntegrityServiceTests.swift
├── BookExportServiceTests.swift
└── BackupMigrationTests.swift
```

最低测试项：

### 缓存

- 缓存路径生成稳定。
- 路径不能穿越 Application Support。
- 空正文不可缓存。
- 超过 8 MB 正文拒绝缓存。
- 缓存文件不存在时判定为失效。
- 缓存文件损坏时会重新下载。
- 并发下载完成后章节路径正确回写。

### 下载任务

- 同书重复任务被拒绝或合并。
- 暂停后不再新增请求。
- 取消后子任务全部停止。
- 失败章节可以单独重试。
- 任务恢复不会重复下载有效缓存。

### 书源

- 同站点不同搜索规则不会被合并。
- 旧占位源迁移幂等。
- 自动检测备注不会影响用户备注。
- 跨域请求移除敏感 header。
- HTTPS 降级时不携带敏感 header。
- 完整检测能区分搜索、目录和正文失败。

### 导出

- 在线正文优先读取有效缓存。
- 缺失正文能够被识别。
- 文件名不包含非法路径字符。
- 同时导出多个书籍不会互相覆盖。

## 14.2 集成测试

必须在 macOS + Xcode 环境执行：

- SwiftData 模型迁移
- 真实 URLSession 请求的 Mock 流程
- 文档选择器导入
- 后台任务恢复
- ShareSheet 导出
- iOS 17 真机离线阅读

## 14.3 UI 测试

核心 UI 流程：

1. 首次启动显示内置书源。
2. 导入远程书源合集。
3. 进入书源详情并保存修改。
4. 批量检测书源。
5. 搜索并加入在线书籍。
6. 下载全书并暂停/恢复。
7. 清理缓存并重新下载。
8. 无网络时打开已缓存章节。
9. 导出在线书籍 TXT。
10. 备份并恢复书架。

## 14.4 性能指标

| 指标 | 目标 |
|---|---:|
| 搜索首批结果展示 | ≤ 3 秒（正常网络） |
| 单章正文请求超时 | 15 秒 |
| 单章正文最大大小 | 8 MB |
| 默认并发下载数 | 3 |
| 下载进度刷新间隔 | 每完成 1 章或最多 500 ms |
| 书源批量检测 | 不阻塞主线程 |
| 书架打开 | 不因缓存扫描明显卡顿 |
| 全书导出 | 10,000 章以内不崩溃 |

---

# 15. 日志与可观测性

建议使用统一日志分类：

```swift
import OSLog

extension Logger {
    static let bookSource = Logger(subsystem: "com.wynx.PureReader", category: "book-source")
    static let download = Logger(subsystem: "com.wynx.PureReader", category: "download")
    static let cache = Logger(subsystem: "com.wynx.PureReader", category: "cache")
    static let backup = Logger(subsystem: "com.wynx.PureReader", category: "backup")
}
```

日志要求：

- 不记录 Cookie、Authorization 或完整请求头。
- 不记录整篇正文。
- 记录 taskID、bookID、chapterID 的脱敏标识。
- 记录耗时、状态、错误类型和重试次数。
- 用户可在设置中导出诊断日志。

示例：

```text
[download] task=AB12 book=CD34 chapter=EF56 status=success bytes=2869 duration=842ms
[book-source] source=GH78 stage=content status=verification-required
```

---

# 16. CI、分支与发布流程

## 16.1 分支建议

```text
main
└── develop
    ├── feature/download-manager
    ├── feature/source-health
    ├── feature/search-coordinator
    ├── feature/book-export
    └── feature/reading-annotations
```

## 16.2 每个功能分支的最低要求

- 修改对应单元测试。
- 执行 `python3 scripts/generate_pbxproj.py --check`。
- 不提交临时缓存、导出文件和本地配置。
- 通过 macOS CI 编译。
- 完成功能验收清单。
- 更新 README 或本开发文档的状态。

## 16.3 发布门禁

发布前必须满足：

- Debug 和 Release 均可编译。
- XCTest 全部通过。
- SwiftData 迁移在旧数据样本上通过。
- 书源导入、搜索、目录、正文链路通过。
- 全书缓存和离线阅读通过。
- 无 P0/P1 未关闭问题。
- 备份恢复通过。
- 隐私和敏感 header 检查通过。

---

# 17. 推荐实施顺序

## Sprint 1：基线修复

1. 修复缓存路径回写。
2. 修复失效缓存判断。
3. 统一下载入口。
4. 增加缓存和书源导入单测。
5. 实现 `example.com` 迁移。

## Sprint 2：下载任务中心

1. 新增 `DownloadTask`。
2. 新增 `DownloadManager`。
3. 接入书籍详情“缓存全书”。
4. 增加暂停、继续、取消、重试。
5. 增加 App 重启恢复。

## Sprint 3：缓存和导出

1. 新增缓存完整性检查。
2. 新增无效缓存清理。
3. 接入统一导出服务。
4. 修复在线书籍 TXT 导出。
5. 增加导出前缺失章节提示。

## Sprint 4：书源健康中心

1. 完整检测流程。
2. 结构化检测结果。
3. 健康中心 UI。
4. 书源评分和排序。
5. 诊断日志。

## Sprint 5：追更和多源搜索

1. `SearchCoordinator`。
2. 多源结果合并。
3. 追更中心。
4. 自动检查策略。
5. 新章节通知。

## Sprint 6：阅读增强

1. 全文搜索。
2. 书签和标注。
3. Markdown / EPUB 导出。
4. 备份字段升级。
5. AI 摘要和上下文问答。

---

# 18. Definition of Done

一个功能只有同时满足以下条件，才算完成：

- 代码已接入真实 UI 流程，不是孤立 Service。
- 数据模型有默认值或迁移方案。
- 成功、失败、取消、超时和重试路径均有处理。
- 不会阻塞主线程。
- 不会跨 Actor 直接访问 SwiftData 模型。
- 关键路径有单元测试。
- 用户可看到明确的状态和错误。
- 不会泄漏敏感请求头或用户数据。
- 支持旧版本数据升级。
- 文档和 README 已更新。
- CI 构建和测试通过。

---

# 19. 首个开发任务拆分

建议首先创建以下任务：

| 编号 | 任务 | 产出 |
|---|---|---|
| DEV-001 | 修复并发下载缓存回写 | 缓存路径和状态正确写入 SwiftData |
| DEV-002 | 修复缓存失效判定 | 缺失/损坏缓存自动重新下载 |
| DEV-003 | 增加旧占位书源迁移 | 升级用户不再保留 `example.com` |
| DEV-004 | 修正书源导入去重 | 不误合并不同规则书源 |
| DEV-005 | 新增 `DownloadTask` 模型 | 可持久化下载任务 |
| DEV-006 | 实现 `DownloadManager` | 队列、暂停、恢复、取消、重试 |
| DEV-007 | 接入书架下载 UI | 用户操作进入统一下载流程 |
| DEV-008 | 新增缓存完整性检查 | 缺失、损坏、孤立文件可识别 |
| DEV-009 | 新增统一导出服务 | TXT、Markdown、HTML、EPUB 统一出口 |
| DEV-010 | 建立书源完整检测 | 搜索、详情、目录、正文四步报告 |

推荐先完成 `DEV-001`～`DEV-004`，再开始 `DEV-005`，避免在不稳定的缓存基础上继续扩展任务系统。

---

## 20. 当前版本交付判断

按照本文规划，建议将版本分为：

### PureReader 1.2

必须包含：

- 缓存一致性修复
- 下载任务中心
- 失效缓存修复
- 可恢复全书下载
- 在线书籍正确导出 TXT
- 旧书源迁移
- 基础书源健康检测

### PureReader 1.3

建议包含：

- 多源搜索协调器
- 书源自动评分
- 追更中心
- 缓存完整性管理
- Markdown / EPUB 导出
- 全文搜索
- 书签和标注

### PureReader 1.4

建议包含：

- AI 章节摘要
- AI 阅读问答
- AI 书架整理
- 远程书源合集版本更新
- 更完善的诊断和数据恢复能力

最终原则：

> 先保证“能下载、能缓存、能离线打开、能恢复、能导出”，再扩大书源数量和 AI 功能范围。
