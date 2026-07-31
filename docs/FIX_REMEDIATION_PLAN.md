# PureReader 后续功能修复实施文档

> 文档版本：1.0  
> 编写日期：2026-07-31  
> 适用工程：`PureReader-ci`  
> 文档性质：代码审查后的修复方案、实施顺序和验收标准

---

## 1. 文档目的

本文件用于指导 PureReader 后续功能的修复、集成和验收。

本阶段已经完成了下载任务、缓存完整性、书源健康检测、多源搜索、统一导出、全文搜索和阅读标注等功能的基础代码，但审查发现：

- 存在明确的编译阻断问题；
- 部分服务只有实现，没有接入真实 UI 流程；
- 下载任务的章节级状态没有闭环；
- 导出结果存在语义、HTML/XML 安全和 EPUB 标准问题；
- `Bookmark` 与 `ReadingAnnotation` 两套标注模型并存；
- 新增功能测试覆盖不足；
- 当前 Windows 环境无法执行 Xcode 编译和 XCTest，必须在 macOS/Xcode CI 中完成最终验证。

本文件的目标是把“审查发现”转化为可执行的修复任务，确保后续代码具备：

```text
可编译
可恢复
可测试
可集成
可迁移
可发布
```

---

## 2. 修复范围

### 2.1 代码范围

主要涉及以下目录：

```text
PureReader/Models/
PureReader/Services/
PureReader/ViewModels/
PureReader/Views/
PureReader/App/
PureReaderTests/
docs/
```

### 2.2 功能范围

| 模块 | 修复目标 |
|---|---|
| 编译阻断 | 修复缺失字段、枚举成员、访问控制和类型外函数问题 |
| 下载任务 | 完善章节级状态、暂停恢复、取消、失败重试和重启恢复 |
| 缓存完整性 | 统一缓存状态、接入检查和清理入口 |
| 多源搜索 | 接入发现页、稳定结果身份、修正合并策略 |
| 书源健康 | 持久化检测历史并参与评分 |
| 导出 | 修复缓存模式、转义内容、完善 EPUB 标准结构 |
| 阅读标注 | 统一新旧标注模型并迁移历史数据 |
| 全文搜索 | 接入 UI，并改为异步后台处理 |
| 备份恢复 | 支持新标注、任务和必要的迁移字段 |
| 测试 | 建立新增功能的单元测试和集成验收清单 |

---

## 3. 当前基线检查结果

### 3.1 已通过检查

```text
python scripts/generate_pbxproj.py --check
→ project.pbxproj is up to date
```

工程文件已经包含后续新增文件，当前不需要手动修改 `project.pbxproj`。

Python 生成脚本语法检查通过，Git 差异检查未发现空白错误。

### 3.2 当前无法执行的检查

当前 Windows 环境没有以下工具：

```text
xcodebuild
swiftc
swift
```

因此暂时无法在本机执行：

- Swift 编译；
- Xcode Debug/Release 构建；
- XCTest；
- SwiftData 真实迁移测试；
- iOS 模拟器验收。

所有 P0 修复完成后，必须在 macOS/Xcode CI 中执行真实构建。

### 3.3 当前发布判断

```text
当前状态：不满足正式发布条件
原因：存在编译阻断问题和多个功能闭环问题
```

---

# 4. P0 编译阻断修复

P0 任务必须全部完成后，才能进入其他功能修复。

---

## P0-001：补充 `BookSourceSnapshot.weight`

### 问题位置

定义文件：

```text
PureReader/Services/BookSourceEngine.swift
```

使用文件：

```text
PureReader/Services/SearchCoordinator.swift
```

`SearchCoordinator.sourceScore` 使用：

```swift
var score = source.weight
```

但 `BookSourceSnapshot` 没有 `weight` 字段。

### 修改方案

在 `BookSourceSnapshot` 中增加：

```swift
var weight: Int
```

在 `init(_ source: BookSource)` 中增加：

```swift
weight = source.weight
```

### 验收标准

- `BookSourceSnapshot` 可以正常初始化；
- `SearchCoordinator.sourceScore` 可以编译；
- 书源排序仍使用原有权重；
- `BookSourceEngine` 中所有快照初始化调用均能通过编译。

---

## P0-002：补充 `ChapterCacheStatus.cancelled`

### 问题位置

定义文件：

```text
PureReader/Models/DownloadTask.swift
```

使用文件：

```text
PureReader/Services/DownloadManager.swift
```

当前存在：

```swift
item.status = .cancelled
```

但枚举中没有 `cancelled`。

### 修改方案

增加：

```swift
case cancelled
```

最终状态：

```swift
enum ChapterCacheStatus: String, Codable, Sendable, CaseIterable {
    case none
    case downloading
    case cached
    case failed
    case invalid
    case cancelled
}
```

### 数据兼容要求

该枚举使用字符串持久化。新增 raw value 不会改变已有数据，但读取未知状态时仍然必须安全回退到 `.none`。

### 验收标准

- 取消任务时章节状态可以写入 `.cancelled`；
- 旧数据库读取不崩溃；
- 任务取消单测通过。

---

## P0-003：修复 `CacheIntegrityService` 的访问控制

### 问题位置

文件：

```text
PureReader/Services/CacheIntegrityService.swift
```

当前方法签名暴露了私有类型：

```swift
static func checkBookDetailed(
    _ book: Book
) -> (
    report: CacheIntegrityReport,
    details: [(Chapter, ChapterCacheValidation)]
)
```

但 `ChapterCacheValidation` 定义为 `private`。

### 推荐修改方案

增加内部值类型：

```swift
enum ChapterCacheValidation: Sendable {
    case valid(bytes: Int64)
    case missing
    case invalid
}
```

推荐不要对外返回 SwiftData `Chapter` 模型，改为值类型：

```swift
struct ChapterCacheDetail: Sendable {
    let chapterID: UUID
    let chapterIndex: Int
    let chapterTitle: String
    let validation: ChapterCacheValidation
}
```

方法改为：

```swift
static func checkBookDetailed(
    _ book: Book
) -> (
    report: CacheIntegrityReport,
    details: [ChapterCacheDetail]
)
```

### 设计原则

- 服务层返回 `Sendable` 值类型；
- 不跨 Actor 返回 SwiftData 模型；
- UI 层只依赖报告和章节 ID；
- 文件系统检查结果与持久化模型解耦。

### 验收标准

- 无访问控制编译错误；
- 详细检查结果可以被测试和 UI 使用；
- 不跨 Actor 传递 `Chapter` 模型。

---

## P0-004：修复 EPUB 打包函数的类型作用域

### 问题位置

文件：

```text
PureReader/Services/BookExportService.swift
```

`createEPUBArchive` 当前位于 `BookExportService` 的类型外部，但仍声明为：

```swift
private static func createEPUBArchive(...)
```

### 修改方案

推荐放入私有 extension：

```swift
private extension BookExportService {
    static func createEPUBArchive(
        from epubDir: URL,
        to epubURL: URL
    ) throws {
        // ZIP 打包逻辑
    }
}
```

### 验收标准

- `BookExportService.export(..., format: .epub)` 可以编译；
- EPUB 打包函数能够被类型内部调用；
- 不出现 `static members may only be declared on a type` 类似错误。

---

# 5. P1 下载任务闭环修复

## 5.1 目标

将当前“任务级进度”升级为“任务级 + 章节级”一致状态。

最终状态来源必须明确：

```text
DownloadTask：任务聚合状态
DownloadTaskItem：章节真实状态
Chapter.offlineCachePath：缓存文件引用
文件系统：缓存实际内容
```

不能只依赖 `DownloadProgress` 的内存回调。

---

## 5.2 `DownloadTaskItem` 状态更新

文件：

```text
PureReader/Services/DownloadManager.swift
PureReader/Services/OnlineLibraryService.swift
```

建议增加结构化结果：

```swift
struct ChapterDownloadResult: Sendable {
    let chapterID: UUID
    let chapterIndex: Int
    let status: ChapterCacheStatus
    let cachePath: String?
    let errorMessage: String?
}
```

下载流程中必须按以下顺序更新：

### 开始下载

```swift
item.status = .downloading
item.errorMessage = nil
```

### 缓存已存在且有效

```swift
item.status = .cached
item.cachePath = chapter.offlineCachePath
item.cachedAt = chapter.offlineCachedAt ?? Date()
```

### 新下载成功

```swift
item.status = .cached
item.cachePath = result.cachePath
item.cachedAt = Date()
item.errorMessage = nil
```

### 下载失败

```swift
item.status = .failed
item.errorMessage = result.errorMessage
item.retryCount += 1
```

### 缓存引用无效

```swift
item.status = .invalid
item.cachePath = nil
item.cachedAt = nil
```

### 任务取消

只将未完成项改为：

```swift
item.status = .cancelled
```

已经 `.cached` 的项必须保留。

---

## 5.3 修复失败章节重试

当前 `retryFailed` 将完整章节数组重新传入，必须改为只处理失败项。

### 处理步骤

1. 查询当前任务的 `DownloadTaskItem`；
2. 筛选状态为 `.failed`、`.invalid` 或 `.none` 的项；
3. 根据 `chapterID` 从当前章节数组中找到对应章节；
4. 清理这些项的错误信息；
5. 只将筛选后的章节传入下载流程；
6. 已缓存章节不重新计入失败任务。

示例：

```swift
let failedItems = fetchTaskItems(
    taskID: taskID,
    statuses: [.failed, .invalid],
    context: context
)

let failedIDs = Set(failedItems.map(\.chapterID))
let retryChapters = chapters.filter {
    failedIDs.contains($0.id)
}
```

### 兼容旧任务

如果历史任务没有 `DownloadTaskItem`，使用缓存完整性回退：

```swift
let retryChapters = chapters.filter { chapter in
    guard let path = chapter.offlineCachePath else { return true }
    return (try? OnlineLibraryService.cachedText(relativePath: path)) == nil
}
```

---

## 5.4 修复重启恢复状态

恢复逻辑必须排除全部终止状态：

```swift
!task.isTerminal
```

推荐逻辑：

```swift
let pending = tasks.filter { !$0.isTerminal }
```

对于恢复任务：

```text
queued/running/cancelling → paused
paused                    → 保持 paused
completed                 → 不处理
completedWithFailures     → 不处理
failed                    → 不处理
cancelled                 → 不处理
```

`completedWithFailures` 必须继续显示：

```text
已完成 378 / 381
失败 3 章
[重试失败章节]
```

不能被覆盖成“上次退出时未完成”。

---

## 5.5 防止暂停恢复竞态

为任务增加执行代次：

```swift
private var taskGenerations: [UUID: UInt64] = [:]
```

每次开始任务时递增：

```swift
let generation = (taskGenerations[taskID] ?? 0) + 1
taskGenerations[taskID] = generation
```

回调写入前验证：

```swift
guard taskGenerations[taskID] == generation else {
    return
}
```

取消任务时递增代次或删除旧代次，使旧任务回调失效。

### 验收场景

```text
开始下载
→ 暂停
→ 立即恢复
→ 旧任务回调不得修改新任务状态
```

---

# 6. P1 多源搜索修复

## 6.1 接入 `SearchCoordinator`

文件：

```text
PureReader/ViewModels/DiscoveryViewModel.swift
PureReader/Services/SearchCoordinator.swift
```

将发现页从旧接口：

```swift
BookSourceEngine.search(...)
```

切换到：

```swift
SearchCoordinator.search(
    keyword: query,
    sources: sources,
    page: 1
)
```

### UI 数据流

```text
SearchSessionReport
    ↓
MergedSearchResult
    ↓
发现页结果行
    ↓
SourceCandidate 选择器
    ↓
sourceID + bookURL
    ↓
目录加载
```

`SourceCandidate` 必须保留，不能为了兼容旧 UI 而丢弃候选来源。

---

## 6.2 稳定 `SourceCandidate.id`

当前不能使用随机 UUID：

```swift
let id = UUID()
```

改为：

```swift
struct SourceCandidate: Identifiable, Hashable, Sendable {
    let sourceID: UUID
    let sourceName: String
    let bookURL: String

    var id: String {
        "\(sourceID.uuidString)|\(bookURL)"
    }
}
```

如果 URL 可能出现大小写、默认端口和 fragment 差异，应先统一规范化。

---

## 6.3 修正搜索结果合并策略

不能仅用：

```text
书名 + 作者
```

作为无条件合并依据。

建议：

### 高置信度

```text
sourceID + canonicalBookURL
```

完全一致时合并。

### 中置信度

```text
标准化书名 + 标准化作者 + 相同域名
```

可以合并，但保留多个候选来源。

### 低置信度

```text
标准化书名 + 标准化作者
```

但域名不同、URL 不同，默认不要直接合并；或标记为“可能为同一本书”。

建议增加：

```swift
enum MergeConfidence: String, Sendable {
    case exact
    case probable
    case separate
}
```

---

# 7. P1 书源健康检测修复

## 7.1 修复无结果状态回调

搜索成功但无结果时必须回调：

```swift
await onStep(.search, .passed, "搜索成功但无结果")
```

后续步骤使用 `.notRun`，而不是 `.failed`：

```swift
await onStep(.detail, .notRun, "搜索无结果，未执行")
await onStep(.catalog, .notRun, "搜索无结果，未执行")
await onStep(.content, .notRun, "搜索无结果，未执行")
```

含义必须区分：

```text
passed    = 已执行且通过
failed    = 已执行但失败
notRun    = 因前置条件不足未执行
unsupported = 当前书源不支持
```

---

## 7.2 增加健康历史持久化

建议新增：

```swift
@Model
final class BookSourceHealthRecord {
    @Attribute(.unique) var id: UUID
    var sourceID: UUID
    var checkedAt: Date

    var searchStatusRaw: String
    var detailStatusRaw: String
    var catalogStatusRaw: String
    var contentStatusRaw: String

    var totalDurationMilliseconds: Int
    var message: String?
}
```

`BookSource` 保存汇总字段：

```swift
var healthScore: Double = 0
var consecutiveFailureCount: Int = 0
var averageLatencyMilliseconds: Int = 0
var lastHealthMessage: String?
```

每次完整检测完成后：

1. 保存 `BookSourceHealthRecord`；
2. 更新 `BookSource` 汇总；
3. 计算健康分；
4. 书源搜索排序使用健康分。

---

## 7.3 健康评分建议

基础评分可以按以下方式设计：

```text
初始权重                         + weight
搜索通过                         + 30
详情通过                         + 20
目录通过                         + 20
正文通过                         + 30
平均响应低于 1 秒                + 10
连续失败每次                     - 15
验证要求                         - 20
搜索失败                         - 30
正文失败                         - 40
```

评分不能替代用户手动启用/禁用状态。健康评分只是排序依据。

---

# 8. P1 导出功能修复

## 8.1 修复 `onlyCachedChapters`

`onlyCachedChapters == true` 时，必须只读取 `offlineCachePath`，不能读取内存正文。

规则：

```text
onlyCachedChapters = true
    → 只读有效离线缓存

onlyCachedChapters = false
    → 优先正文内存
    → 没有内存正文时回退离线缓存
```

需要为两个模式分别增加测试。

---

## 8.2 增加 HTML/XML 转义

新增统一方法：

```swift
private static func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
```

必须先处理 `&`。

需要转义：

- 书名；
- 作者；
- 章节标题；
- 正文段落；
- HTML `<title>`；
- EPUB `<dc:title>`；
- EPUB `<dc:creator>`；
- HTML/XML 属性值。

如果未来支持安全的富文本 HTML，需要先通过白名单清洗，而不是直接拼接原始 HTML。

---

## 8.3 完善 EPUB 标准结构

EPUB 根目录必须包含：

```text
mimetype
META-INF/container.xml
OEBPS/content.opf
OEBPS/chapter-*.xhtml
```

`mimetype` 内容必须是：

```text
application/epub+zip
```

同时要求：

- `mimetype` 是 ZIP 第一个文件；
- `mimetype` 不压缩；
- `container.xml` 指向正确的 OPF；
- OPF 中的 manifest 和 spine 数量一致；
- 每个 XHTML 都是合法 XML/XHTML；
- 所有标题和正文均完成转义。

如果 `FileManager.zipItem` 无法控制“首文件不压缩”，则必须改用现有 `ZIPUtility` 或扩展 ZIP 打包实现。

---

## 8.4 接入导出前检查

书架导出流程改为：

```text
点击导出
    ↓
BookExportService.checkExportAvailability
    ↓
显示导出确认页
    ↓
用户选择导出模式
    ↓
执行导出
```

确认页至少显示：

```text
总章节：381
正文可用：378
缓存可用：2
缺失：1
```

提供：

```text
导出全部可用内容
只导出缓存章节
取消
```

禁止静默跳过缺失章节。

---

## 8.5 处理 `includeCover`

当前 `includeCover` 已定义，但尚未形成完整导出流程。

必须二选一：

### 方案 A：实现封面导出

- 将 `book.coverImageData` 写入导出目录；
- HTML 插入 `<img>`；
- EPUB manifest 加入 cover image；
- OPF 加入封面 metadata；
- 没有封面时跳过，不生成空引用。

### 方案 B：暂时删除该选项

如果本版本不实现封面导出，应删除 `includeCover`，避免产生错误预期。

推荐方案 A。

---

# 9. P1 阅读标注统一

## 9.1 目标

项目只能保留一个正式标注数据源。

推荐统一使用：

```text
ReadingAnnotation
```

旧 `Bookmark` 仅作为迁移来源或短期兼容模型。

---

## 9.2 迁移范围

需要修改：

```text
PureReader/ViewModels/ReaderViewModel.swift
PureReader/Views/Reader/BookmarkListView.swift
PureReader/Views/Reader/PageContent.swift
PureReader/Services/BackupService.swift
PureReader/Services/BookImportService.swift
```

阅读器中的以下功能全部切换到 `AnnotationService`：

- 添加位置书签；
- 添加高亮；
- 添加笔记；
- 修改笔记；
- 删除标注；
- 查询当前章节标注；
- 跳转到标注位置。

---

## 9.3 旧数据迁移

迁移规则：

| 旧 `Bookmark` 字段 | 新 `ReadingAnnotation` 字段 |
|---|---|
| `bookID` | `bookID` |
| `chapterID` | `chapterID` |
| `chapterIndex` | `chapterIndex` |
| `excerpt` | `selectedText` |
| `note` | `note` |
| `colorRaw` | `colorRaw` |
| `utf16Location` | `pageOffset` 或新增独立位置字段 |
| `utf16Length == 0` | 位置书签 |
| `utf16Length > 0` | 高亮 |

注意：旧模型使用 UTF-16 位置和长度，新模型目前主要使用 `pageOffset`。如果需要精确恢复高亮范围，应在 `ReadingAnnotation` 中增加：

```swift
var utf16Location: Int
var utf16Length: Int
```

不能仅依赖页面偏移替代文本范围，否则正文重新分页或字号变化后可能无法准确恢复高亮。

---

## 9.4 删除书籍时清理全部标注

删除书籍时必须同时清理：

```text
ReadingAnnotation
Bookmark
RewriteRecord
DownloadTask
DownloadTaskItem
离线缓存
AI 向量索引
AI 记忆锚点
```

所有数据清理完成后再提交事务，避免留下孤立记录。

---

# 10. P1 备份恢复修复

## 10.1 增加新标注备份字段

`BackupArchive` 增加：

```swift
var annotations: [BackupAnnotation]
```

旧备份兼容：

```swift
annotations = try decoder.decodeIfPresent(
    [BackupAnnotation].self,
    forKey: .annotations
) ?? []
```

需要升级：

```swift
BackupArchive.currentSchemaVersion
```

## 10.2 备份内容

`BackupAnnotation` 至少包含：

```swift
struct BackupAnnotation: Codable, Sendable {
    let id: UUID
    let bookID: UUID
    let chapterID: UUID?
    let chapterIndex: Int
    let selectedText: String
    let note: String
    let colorRaw: String
    let pageOffset: Int
    let createdAt: Date
    let updatedAt: Date
}
```

如果增加 UTF-16 定位字段，也必须加入备份。

## 10.3 恢复验收

- 新标注可以备份；
- 新标注可以恢复；
- 旧备份没有 `annotations` 时不失败；
- 重复恢复不会重复插入；
- 删除书籍后恢复数据不会产生孤立标注。

---

# 11. P1 全文搜索接入

## 11.1 UI 入口

推荐入口：

```text
书籍详情页
    ↓
搜索本书
    ↓
输入关键词
    ↓
TextSearchService
    ↓
章节命中列表
    ↓
点击命中
    ↓
阅读器跳转到章节和位置
```

## 11.2 搜索值类型

后台搜索不能直接跨 Actor 持有 SwiftData 模型。

建议定义：

```swift
struct SearchChapterInput: Sendable {
    let id: UUID
    let index: Int
    let title: String
    let content: String
    let cachePath: String?
}
```

先在主 Actor 读取数据，再将值类型传入后台。

## 11.3 异步接口

建议接口：

```swift
static func search(
    query: String,
    chapters: [SearchChapterInput],
    onProgress: @escaping @Sendable (Int, Int) -> Void
) async -> [TextSearchHit]
```

搜索必须支持取消：

```swift
try Task.checkCancellation()
```

## 11.4 跳转定位

`TextSearchHit` 不应只保存字符位置，还应保存：

```swift
let chapterID: UUID
let chapterIndex: Int
let matchPosition: Int
```

点击结果后：

```text
优先使用 chapterID 定位
chapterIndex 作为后备
matchPosition 恢复阅读位置
```

---

# 12. P2 缓存完整性接入

## 12.1 书籍详情入口

展示：

```text
缓存状态
有效章节
缺失章节
损坏章节
孤立文件
缓存占用
```

## 12.2 设置页入口

提供：

```text
扫描全部在线书籍
清理无效缓存引用
清理孤立缓存文件
```

## 12.3 与下载、导出联动

下载前：

```text
检查已有缓存
跳过有效缓存
重新下载无效缓存
```

导出前：

```text
检查章节内容
区分内存正文和离线缓存
显示缺失章节
```

删除书籍时：

```text
取消下载任务
删除 SwiftData 任务记录
删除离线缓存目录
清理孤立文件
```

---

# 13. SwiftData 数据迁移要求

## 13.1 不要静默切换内存数据库

当前初始化失败时切换到内存库，会让用户看到空书架，存在误判数据丢失的风险。

正式版本建议：

```text
持久化库初始化失败
    ↓
记录完整错误
    ↓
显示数据库恢复页面
    ↓
提示备份数据库文件
    ↓
提供重试、恢复或导入选项
```

## 13.2 建立显式迁移版本

建议使用：

```swift
SchemaMigrationPlan
```

为新增模型和字段提供迁移阶段：

```text
VersionedSchema.V1
VersionedSchema.V2
VersionedSchema.V3
```

## 13.3 必须测试的迁移内容

- 新增 `DownloadTask`；
- 新增 `DownloadTaskItem`；
- 新增 `ReadingAnnotation`；
- `BookSource.weight`；
- `BookSource.exploreURL`；
- `Chapter.offlineCachePath`；
- `Chapter.offlineCachedAt`；
- 新标注字段；
- 旧 Bookmark 到新标注的迁移。

---

# 14. 测试实施计划

## 14.1 新增测试文件

建议新增：

```text
PureReaderTests/DownloadTaskTests.swift
PureReaderTests/DownloadManagerTests.swift
PureReaderTests/BookExportServiceTests.swift
PureReaderTests/CacheIntegrityServiceTests.swift
PureReaderTests/SearchCoordinatorTests.swift
PureReaderTests/TextSearchServiceTests.swift
PureReaderTests/ReadingAnnotationTests.swift
PureReaderTests/BookSourceHealthTests.swift
PureReaderTests/BackupServiceTests.swift
```

## 14.2 P0 编译验收

```text
BookSourceSnapshot 初始化通过
ChapterCacheStatus.cancelled 编译通过
CacheIntegrityService 访问级别通过
BookExportService EPUB helper 编译通过
```

## 14.3 下载测试

```text
任务创建后章节项数量正确
任务状态保存成功
章节状态从 none → downloading → cached
章节失败后写入 failed
取消后未完成项写入 cancelled
重试只处理 failed 项
completedWithFailures 重启后保持终止状态
暂停恢复不会出现旧任务回写
```

## 14.4 搜索测试

```text
最大并发数不超过 5
单源超时进入 failures
单源失败不影响其他源
SearchSessionReport 计数正确
SourceCandidate.id 稳定
不同作品不会错误合并
```

## 14.5 导出测试

```text
onlyCachedChapters 只导出缓存
默认模式优先内存正文
HTML 特殊字符转义
EPUB 包含 mimetype
EPUB mimetype 位于首文件且不压缩
空章节不生成错误 XML
缺失章节提示正确
```

## 14.6 标注测试

```text
书签创建成功
高亮创建成功
笔记创建成功
修改笔记成功
删除标注成功
旧 Bookmark 迁移成功
备份包含 ReadingAnnotation
恢复不会重复插入
```

---

# 15. 实施顺序

## Sprint A：编译恢复

目标：恢复工程可编译。

任务：

1. P0-001 增加 `weight`；
2. P0-002 增加 `cancelled`；
3. P0-003 修复缓存状态访问控制；
4. P0-004 修复 EPUB helper 作用域；
5. 运行工程文件同步检查；
6. 在 macOS 执行 Debug 编译。

完成标准：

```text
Debug 编译通过
Release 编译通过
```

---

## Sprint B：下载任务闭环

目标：使下载任务真正可恢复、可重试、可追踪。

任务：

1. 完成 `DownloadTaskItem` 状态写回；
2. 改造下载结果为结构化值类型；
3. 只重试失败章节；
4. 修复完成失败任务的重启恢复；
5. 增加执行代次；
6. 删除书籍时清理下载任务；
7. 增加下载单测。

完成标准：

```text
下载成功、失败、暂停、恢复、取消、重试全部可验证
```

---

## Sprint C：多源搜索和健康中心

目标：让新增服务真正接入发现页，并形成书源质量反馈。

任务：

1. DiscoveryViewModel 接入 SearchCoordinator；
2. 适配合并结果和候选来源；
3. 稳定候选 ID；
4. 修复跨作品误合并；
5. 保存健康检测历史；
6. 计算健康评分；
7. 健康分参与书源排序；
8. 增加搜索和健康测试。

完成标准：

```text
发现页真实使用多源搜索
健康检测结果可持久化并影响排序
```

---

## Sprint D：导出和缓存完整性

目标：确保导出内容正确、安全、兼容。

任务：

1. 修复缓存模式；
2. 增加 HTML/XML 转义；
3. 增加 EPUB mimetype；
4. 修复 ZIP 存储顺序和压缩方式；
5. 接入导出前检查；
6. 接入缓存完整性 UI；
7. 增加导出和缓存测试。

完成标准：

```text
TXT、Markdown、HTML、EPUB 均可导出
缺失章节有明确提示
```

---

## Sprint E：统一标注和备份

目标：移除双模型并保证用户数据不丢失。

任务：

1. 迁移阅读器到 `ReadingAnnotation`；
2. 迁移书签列表和高亮渲染；
3. 编写旧 Bookmark 迁移；
4. 备份加入新标注；
5. 删除书籍时清理两套数据；
6. 增加迁移和备份恢复测试。

完成标准：

```text
书签、高亮、笔记只有一个正式数据源
旧数据可以迁移
备份恢复完整
```

---

## Sprint F：全文搜索和最终验收

目标：把全文搜索变成用户可使用功能，并完成发布门禁。

任务：

1. 添加书籍内搜索入口；
2. 搜索改为异步；
3. 支持进度和取消；
4. 支持点击跳转；
5. macOS Debug/Release 构建；
6. 执行 XCTest；
7. 执行迁移测试；
8. 进行真机或模拟器验收；
9. 关闭全部 P0/P1 问题。

---

# 16. Definition of Done

只有同时满足以下条件，修复阶段才算完成：

## 编译

- Debug 编译通过；
- Release 编译通过；
- 无新增编译警告影响功能；
- 工程文件同步检查通过。

## 数据

- SwiftData Schema 初始化通过；
- 旧版本数据迁移通过；
- 新标注可以备份恢复；
- 删除书籍不会留下孤立数据。

## 下载

- 成功、失败、暂停、恢复、取消、重试均有测试；
- 章节级任务状态与缓存实际状态一致；
- App 重启后状态正确；
- 旧任务不会覆盖新任务。

## 搜索

- 发现页真实接入多源搜索；
- 并发限制和超时生效；
- 结果候选身份稳定；
- 不会误合并不同作品。

## 导出

- 缓存模式语义正确；
- HTML/XML 特殊字符完成转义；
- EPUB 结构符合标准；
- 缺失章节向用户明确展示。

## 标注

- 阅读器、书签列表、备份恢复使用同一模型；
- 旧 Bookmark 可以迁移；
- 删除书籍时标注全部清理。

## 测试

- 新增核心服务均有单元测试；
- macOS XCTest 全部通过；
- 旧数据迁移样本测试通过；
- 真机或模拟器核心流程验收通过。

---

# 17. 发布门禁

以下任一项不满足，都不得进入正式发布：

```text
存在 P0 问题
存在未解释的编译错误
Debug 或 Release 构建失败
XCTest 失败
SwiftData 迁移失败
下载任务无法恢复
多源搜索未接入真实 UI
HTML/XML 导出未转义
EPUB 缺少标准 mimetype
标注备份恢复不完整
删除书籍留下持久化孤立数据
```

最终发布判断：

```text
P0 = 0
P1 = 0
关键 XCTest = 全部通过
Debug = 通过
Release = 通过
迁移 = 通过
```

---

# 18. 本阶段建议状态

当前建议在项目看板中标记为：

```text
后续功能：框架完成，修复和集成中
```

不建议标记为：

```text
已完成
可发布
验收通过
```

建议下一项开发任务为：

```text
FIX-001：恢复编译并完成 P0 修复
```

完成 FIX-001 后再进入：

```text
FIX-002：下载任务状态闭环
FIX-003：多源搜索接入
FIX-004：导出和 EPUB 修复
FIX-005：标注模型统一
FIX-006：测试和发布验收
```
