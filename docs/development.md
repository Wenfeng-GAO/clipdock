# ClipDock - iOS 外接存储视频迁移 App 开发文档

## 1. 开发目标

在 iOS 平台实现一个可用的 MVP，完成以下闭环：
1. 扫描相册视频并按日期排序。
2. 用户手动选择视频。
3. 迁移到外接存储。
4. 校验成功后删除源视频。
5. 展示任务结果与失败原因。

## 2. 技术方案

### 2.1 总体架构
采用 `SwiftUI + MVVM` 分层：
1. UI 层（SwiftUI）：页面与交互。
2. ViewModel 层：状态管理、流程编排。
3. Service 层：相册访问、文件写入、迁移执行、校验、记录持久化。
4. Storage 层：本地任务记录与目标目录书签管理。

### 2.2 关键流程设计
1. 目录准备：
   - 用户通过 `UIDocumentPickerViewController` 选择目录。
   - 保存 `security-scoped bookmark`。
2. 视频读取：
   - 使用 `PhotoKit` 查询视频 `PHAsset`，按 `creationDate` 排序。
3. 手动选择：
   - ViewModel 管理 `selectedAssetIDs`。
4. 迁移执行：
   - 使用 `PHAssetResourceManager` 或导出 API 获取视频文件。
   - 写入外接存储目标目录。
5. 校验：
   - 文件存在性、大小一致性、可读性校验。
6. 删除：
   - 对已校验成功资产执行 `PHPhotoLibrary.performChanges` 删除。
7. 持久化记录：
   - 保存任务与条目状态，支持异常恢复。

### 2.3 框架与 API 选型
1. `SwiftUI`：界面搭建。
2. `PhotoKit`：视频资产查询、删除。
3. `UniformTypeIdentifiers`：文件类型识别。
4. `Foundation/FileManager`：目录和文件写入。
5. `OSLog`：日志采集。
6. `CoreData`（或轻量 SQLite 封装）：任务状态持久化。

选型说明：
1. `SwiftUI` 提升 MVP 开发效率，适合快速迭代。
2. `PhotoKit` 是 iOS 相册访问与删除的官方能力。
3. 需要本地持久化以支持中断恢复，优先 `CoreData` 降低手写存储风险。

## 3. 模块拆分

### 3.1 模块列表
1. `PermissionModule`：权限申请与状态检测。
2. `ExternalStorageModule`：目录选择、bookmark 管理、访问有效性检查。
3. `MediaScanModule`：视频扫描、排序、列表分页加载。
4. `SelectionModule`：选择状态管理（多选/全选）。
5. `MigrationModule`：导出、写入、失败重试、进度汇总。
6. `ValidationModule`：迁移后完整性校验。
7. `DeletionModule`：删除源视频与结果回写。
8. `TaskRecordModule`：任务记录与历史结果展示。

### 3.2 关键数据模型（示例）
1. `VideoAssetItem`
   - `assetLocalID: String`
   - `creationDate: Date`
   - `duration: Double`
   - `estimatedSize: Int64?`
2. `MigrationTask`
   - `taskID: UUID`
   - `createdAt: Date`
   - `targetFolderBookmark: Data`
   - `status: pending/running/paused/completed/failed`
3. `MigrationTaskItem`
   - `assetLocalID: String`
   - `status: pending/copying/validating/success/failed/deleted`
   - `targetFilePath: String?`
   - `errorCode: String?`

## 4. 执行步骤（工程拆解）

### 阶段 1：工程初始化
1. 创建 Xcode 工程与基本目录结构。
2. 配置权限描述（Photos、文件访问）。
3. 搭建日志与错误码体系。

### 阶段 2：基础能力打通
1. 完成目录选择 + bookmark 持久化。
2. 完成视频扫描与日期排序列表。
3. 完成手动选择能力（多选/全选/统计）。

### 阶段 3：迁移主链路
1. 迁移执行器（串行优先，后续可控并发）。
2. 单文件状态机（copy -> validate -> success）。
3. 失败重试机制与中断恢复。

### 阶段 4：删除与结果闭环
1. 删除确认弹窗与安全拦截。
2. 删除源视频并刷新列表。
3. 历史任务页与失败原因展示。

### 阶段 5：稳定性与发布准备
1. 外设拔出、权限变化、空间不足等异常处理。
2. 性能优化与内存控制。
3. Beta 构建与测试修复。

## 5. 验证步骤（测试计划）

### 5.1 功能验证
1. 权限流：首次拒绝、再次授权、限制访问。
2. 扫描排序：空库、少量（<50）、大量（>1000）视频。
3. 手动选择：多选、全选、取消、切换页面后状态保持。
4. 迁移：mov/mp4 格式、不同大小、长视频。
5. 删除：仅成功项可删，删除后相册确认不可见。

### 5.2 异常验证
1. 迁移中拔出外接存储。
2. 目标目录不可写或权限失效。
3. iPhone 剩余空间紧张。
4. App 强退后恢复任务状态。

### 5.3 性能验证
1. 1000+ 视频扫描耗时。
2. 长任务内存峰值与泄漏检查。
3. 迁移吞吐（MB/s）和进度刷新频率稳定性。

### 5.4 验收标准
1. 主链路成功率达到 PRD 指标。
2. 无 P0/P1 阻断缺陷。
3. 异常场景可预期失败并可恢复。

## 6. 风险与技术对策

1. 相册导出差异风险：
   - 对不同来源视频（拍摄/下载/编辑）做样本覆盖测试。
2. 外接存储兼容性风险：
   - 先限定支持范围（常见 U 盘/SSD + 可写文件系统）。
3. 删除不可逆风险：
   - 强制二次确认 + 删除前再次校验。
4. 长任务稳定性风险：
   - 任务持久化、分步提交、可重入执行器。

## 7. 代码规范与分支策略

1. 分支策略：`main` + 功能分支（如 `feature/migration-executor`）。
2. 提交规范：一个提交只解决一类问题。
3. CI 建议：
   - 编译检查
   - 单元测试
   - 基础静态检查

## 8. 问题记录与阶段性总结（Dev Log）

### 8.1 记录规则（后续开发必须遵守）
每完成一个最小模块（M0-M9）或每修复一次阻断问题，更新本节追加一条记录，格式固定为：
1. 日期（YYYY-MM-DD）
2. 现象（用户可见/开发可见）
3. 根因（尽量指到具体 API/配置/文件）
4. 解决方案（改了哪些文件/关键点）
5. 验证方法（如何确认已修复，真机/命令行/复现场景）

补充（耗时统计口径）：
1. “阶段耗时”默认用 git commit 时间线粗略估算（见 `docs/project-plan.md`）。
2. 若某阶段跨越多次会话或包含大量真机验证等待，可在记录中额外写“人工等待/外设操作”耗时。

### 8.2 记录

#### 2026-02-12 - Build 失败：security-scoped bookmark 选项不可用于 iOS
1. 现象：
   - `xcodebuild` 编译失败，报错 `withSecurityScope is unavailable in iOS`。
2. 根因：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Services/ExternalStorage/ExternalStorageService.swift` 使用了 `URL.BookmarkCreationOptions.withSecurityScope` / `URL.BookmarkResolutionOptions.withSecurityScope`，该能力是 macOS 专用。
3. 解决方案：
   - iOS 改为 `.minimalBookmark`，并保留 macOS 条件编译分支继续使用 `.withSecurityScope`。
4. 验证方法：
   - 运行 `xcodebuild -project ClipDock.xcodeproj -scheme ClipDock -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` 验证 `BUILD SUCCEEDED`。

#### 2026-02-12 - 点 Grant Access 闪退：缺少 Photos 权限用途说明
1. 现象：
   - 真机点击 `Grant Access` 后 App 立刻退出（闪退）。
2. 根因：
   - 打包进 App 的 `Info.plist` 缺少 `NSPhotoLibraryUsageDescription` / `NSPhotoLibraryAddUsageDescription`，iOS 在触发相册权限请求时会强制终止进程。
3. 解决方案：
   - 补齐 `/Users/wenfeng/Documents/iphoneapp/ClipDock/Info.plist` 中 Photos 相关用途说明 key（以及必要的基础字段）。
4. 验证方法：
   - `xcodebuild ...` 重新编译后，从产物 `ClipDock.app/Info.plist` 确认 key 存在；真机再次点击 `Grant Access` 不再闪退并能弹出系统权限框。

#### 2026-02-12 - 重新运行 xcodegen 后隐私说明丢失：Info.plist 被生成器覆盖
1. 现象：
   - 运行 `xcodegen generate` 后，`ClipDock/Info.plist` 变回最小内容，导致 Photos 权限说明 key 丢失，存在闪退风险回归。
2. 根因：
   - `project.yml` 使用 `targets.ClipDock.info.path`，xcodegen 会在生成过程中覆盖该路径的 plist 内容。
3. 解决方案：
   - 将隐私说明等关键键值固化到 `project.yml` 的 `targets.ClipDock.info.properties`，由生成器持续写入，避免手工编辑丢失。
4. 验证方法：
   - `xcodegen generate` 后用 `plutil -p ClipDock/Info.plist` 确认 `NSPhotoLibraryUsageDescription` 等 key 存在；真机点击 `Grant Access` 不闪退。

#### 2026-02-12 - M4/M5：手动选择 + 最小迁移（复制到外接目录）
1. 现象：
   - 需要在扫描列表中手动选择视频，并将选中视频复制到外接目录，展示进度。
2. 根因：
   - 这是 MVP 主链路中的核心能力，需要在 UI、状态管理、导出写入之间打通闭环。
3. 解决方案：
   - `M4`：在 `HomeViewModel` 引入 `selectedVideoIDs`，支持多选/全选/清空与选中计数；列表行显示勾选状态。
   - `M5`：新增 `VideoMigrationService`，使用 `PHAssetResourceManager` 将选中视频资源写入目标目录，提供迁移进度回调；目前只做“复制+最小校验”，删除源视频留到下一步。
4. 验证方法：
   - 编译验证：`xcodebuild -project ClipDock.xcodeproj -scheme ClipDock -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`。
   - 真机验证（需要外接存储）：选中 1-2 个视频，点击 `Start Migration`，在外接目录可见导出的文件且大小 > 0。

#### 2026-02-12 - 迁移 Copy 失败：外接盘无权限（你 don’t have permission to access）
1. 现象：
   - 迁移时报错类似：`couldn't be copied because you don't have permission to access "<ExternalVolumeName>"`。
2. 根因（推断，基于 iOS 文件提供者/外接存储行为）：
   - 迁移过程未能稳定持有外接目录的 security scope，或对外接盘的写入需要文件协调（`NSFileCoordinator`）才能在某些 provider/外接盘上成功。
3. 解决方案：
   - 在迁移开始时对目标目录 `startAccessingSecurityScopedResource()`，并在整个迁移任务期间保持开启；若无法开启则提示用户重新选择外接目录。
   - 导出流程固定为“先导出到 App 临时目录，再用 `NSFileCoordinator` 协调写入外接盘（forReplacing）”。
   - 同步增强错误信息：将 domain/code 带出，便于定位失败类型。
4. 验证方法：
   - 真机外接盘：重新选择外接目录后迁移 1 个视频，确认外接盘出现导出文件且可播放。

5. 复测结果：
   - 复测通过（用户确认迁移完成弹窗出现，外接盘可见导出文件）。

#### 2026-02-12 - M9：显示视频大小 + 按大小排序（正序/倒序）
1. 现象：
   - 需要在视频列表中展示每条视频的大小，并支持按大小排序（从大到小/从小到大），同时保留按日期排序能力。
2. 根因：
   - PhotoKit 的 `PHAsset` 在公开 API 中不直接暴露“文件大小”字段，需要额外从资源层获取（或通过导出计算），并注意不要对 1000+ 视频做全量 IO。
3. 解决方案：
   - 文件 `/Users/wenfeng/Documents/iphoneapp/ClipDock/Services/PhotoLibrary/VideoLibraryService.swift`：
     新增批量读取大小方法 `fetchVideoFileSizesBytes(assetIDs:)`，通过 `PHAssetResource.assetResources(for:)` 并用 KVC 读取 `fileSize`（MVP 用）。
   - 文件 `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeViewModel.swift`：
     新增 `sortMode`（Date/Size Largest/Size Smallest）、`videoSizeBytesByID` 缓存与“首屏（200）预取 + 行内按需加载”策略；按大小排序时将未知 size 的条目放到列表底部，并以 `creationDate desc` 做 tie-breaker。
   - 文件 `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeView.swift`：
     新增分段控件切换排序方式；列表行新增 `Size: ...` 展示。
4. 验证方法：
   - 编译验证：`xcodegen generate` + `xcodebuild -project ClipDock.xcodeproj -scheme ClipDock -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`。
5. 风险说明：
   - 当前读取大小使用了 KVC（`value(forKey: "fileSize")`），不是公开 API 合约，可能在未来 iOS 版本失效，或不适合 App Store 上架场景；失效时会显示 `--`，且大小排序会把未知项放到底部。

#### 2026-02-12 - 国际化（中英文双语，默认跟随系统）
1. 现象：
   - 需要支持中文（简体）与英文两种语言，并默认跟随系统语言，无需应用内单独语言开关。
2. 根因：
   - 之前 UI/错误提示字符串大多为英文硬编码，系统切换中文后仍显示英文。
3. 解决方案：
   - 新增本地化资源：
     - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Resources/en.lproj/Localizable.strings`
     - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Resources/zh-Hans.lproj/Localizable.strings`
   - 新增轻量本地化工具：
     - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Localization/L10n.swift`
   - 将非 `Text("...")` 直出的动态文案、错误描述（`LocalizedError`）、以及 ViewModel 中的提示信息改为走 `L10n.tr(...)`，确保随系统语言变化。
4. 验证方法：
   - 编译验证：`xcodegen generate` + `xcodebuild -project ClipDock.xcodeproj -scheme ClipDock -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`。
   - 真机验证（后续）：iOS 设置中切换语言为中文，确认关键页面与弹窗文案为中文；切换回英文后恢复英文。

#### 2026-02-12 - 单元测试与回归（覆盖大量/大视频等边界）
1. 现象：
   - 需要补充单元测试，对 MVP 主链路做回归验证，并覆盖“视频很多/很大”的边界情况。
2. 根因：
   - 现阶段业务逻辑主要集中在 `HomeViewModel` 的流程编排与状态机；真实 PhotoKit/外接盘导出不适合在单测环境中跑，需要用 mock 分层验证行为与边界。
3. 解决方案：
   - 新增 `ClipDockTests` 单元测试 Target（xcodegen 管理），并启用 `GENERATE_INFOPLIST_FILE=YES` 避免测试 bundle 缺 plist 导致无法运行。
   - 新增 mock（Test Doubles）覆盖：
     - 权限/扫描 guardrail（拒绝权限不触发扫描）
     - 迁移 guardrail（无目录/不可写/无选择不触发迁移）
     - 大量视频（5k 条）全选不崩溃（逻辑层验证）
     - 大小预取 cap=200 的策略正确、按大小排序未知项在底部
     - 迁移调用参数顺序稳定、删除只删 lastRun success
     - 历史记录落盘 maxRecords 截断逻辑
   - 关键文件：
     - `/Users/wenfeng/Documents/iphoneapp/project.yml`
     - `/Users/wenfeng/Documents/iphoneapp/ClipDockTests/TestDoubles.swift`
     - `/Users/wenfeng/Documents/iphoneapp/ClipDockTests/HomeViewModelGuardrailTests.swift`
     - `/Users/wenfeng/Documents/iphoneapp/ClipDockTests/HomeViewModelSelectionTests.swift`
     - `/Users/wenfeng/Documents/iphoneapp/ClipDockTests/HomeViewModelSortAndSizeTests.swift`
     - `/Users/wenfeng/Documents/iphoneapp/ClipDockTests/HomeViewModelMigrationAndDeletionTests.swift`
     - `/Users/wenfeng/Documents/iphoneapp/ClipDockTests/MigrationHistoryStoreTests.swift`
4. 验证方法：
   - 本地回归（Simulator）：`xcodegen generate` + `xcodebuild -project ClipDock.xcodeproj -scheme ClipDock -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' CODE_SIGNING_ALLOWED=NO test`
5. 结果：
   - 回归通过：共 12 个测试用例，0 failure（2026-02-12 21:48 +08:00）。

#### 2026-02-12 - git push GitHub 失败：需要显式配置 git 走本机代理端口
1. 现象：
   - 命令行执行 `git push origin main` 长时间超时，报错类似：`Failed to connect to github.com port 443 ... Couldn't connect to server`。
2. 根因：
   - 当前网络环境下直连 GitHub 会超时，但系统已配置本机代理（`127.0.0.1:7897`）。`git`（libcurl）默认不会自动读取 macOS 的系统代理配置，因此需要显式设置 `http(s).proxy` 才能走代理。
3. 解决方案：
   - 在仓库本地配置（仅影响本 repo，不污染全局）：
     - `git config http.proxy http://127.0.0.1:7897`
     - `git config https.proxy http://127.0.0.1:7897`
4. 验证方法：
   - `git ls-remote origin` 能正常返回 refs。
   - `git push origin main` 成功完成推送。

#### 2026-02-12 - M10：回归前收尾（分页加载/仅看已选/失败详情/删除权限收紧）
1. 现象：
   - 大量视频场景下需要更可控的列表浏览（加载更多、只看已选），并在迁移失败时能在首页直接看到失败原因；同时删除操作应明确要求“完全访问”权限。
2. 根因：
   - 列表此前固定只展示前 200 条且没有“仅看已选”；迁移失败原因需要进入 History 才能看到；删除逻辑仅校验 `canReadLibrary`，与“删除需要完全访问”的提示不一致。
3. 解决方案：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeViewModel.swift`：
     - 增加 `listVisibleLimit`（默认 200）+ `loadMoreVideos()`；增加 `showSelectedOnly`；size 预取范围调整为“当前可见范围”。
     - 删除逻辑改为 `permissionState.canDeleteFromLibrary`（仅 `.authorized`）。
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeView.swift`：
     - 增加 `Show Selected Only` 开关、`Load More` 按钮。
     - `Post-Migration` 增加失败列表 `DisclosureGroup`（最多 20 条）+ 一键复制错误信息；并提供“最近一次运行详情”直达入口。
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/History/HistoryView.swift`：
     - 将 `HistoryDetailView` 从 `private` 调整为可复用，供首页跳转复用。
4. 验证方法：
   - 编译验证：`xcodegen generate` + `xcodebuild ... build`（iOS）。
   - 回归验证：`xcodebuild ... test`（Simulator，12 tests / 0 failure）。
   - 备注：`xcodebuild test` 在本机出现“Result bundle saving failed (mkstemp: No such file or directory)”警告，但测试用例执行结果为 `TEST SUCCEEDED`，不影响回归结论。

#### 2026-02-13 - xcodebuild test 失败：build.db 锁冲突（并发 build/test）
1. 现象：
   - 运行 `xcodebuild test` 报错：`database is locked Possibly there are two concurrent builds running in the same filesystem location.`。
2. 根因：
   - 同时触发了两条 `xcodebuild`（build + test）并共享同一个 DerivedData，导致 build database 被占用。
3. 解决方案：
   - 避免并发跑 build/test；或为 `xcodebuild test` 指定独立 `-derivedDataPath`（例如 `/tmp/ClipDockDerivedDataTest.XXXXXX`）。
4. 验证方法：
   - `xcodebuild ... -derivedDataPath /tmp/... test` -> `TEST SUCCEEDED`（12 tests / 0 failure，2026-02-13 00:12 +08:00）。

#### 2026-02-13 - App Store 准备：移除 `fileSize` KVC（避免非公开行为风险）
1. 现象：
   - 列表“按大小排序/显示大小”此前通过 `PHAssetResource` 的 KVC 读取 `fileSize`，存在依赖非公开实现细节的风险。
2. 根因：
   - `PHAsset` 没有公开的“文件大小”字段；KVC 读取属于实现细节，未来 iOS 版本可能失效，且可能影响上架审核风险。
3. 解决方案：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Services/PhotoLibrary/VideoLibraryService.swift`：
     - 改为使用 `PHImageManager.requestAVAsset(forVideo:)`（public API）拿到 `AVURLAsset` 时读取本地文件大小（best-effort）。
     - `isNetworkAccessAllowed=false`：仅对已在本地的资源返回 size，iCloud-only 资源 size 继续显示 `--`。
4. 验证方法：
   - `xcodebuild ... test`（Simulator） -> `TEST SUCCEEDED`（12 tests / 0 failure，2026-02-13 01:06 +08:00）。

---

## 最终总结（MVP -> Beta）

### 已交付功能（对齐 PRD / MVP）
1. 扫描：PhotoKit 拉取视频资产，默认按日期倒序，支持“按大小排序”，并展示大小（未知显示 `--`）。
2. 选择：列表多选/全选/清空/仅看已选，选中数量联动迁移区块。
3. 外接目录：Document Picker 选择目录并持久化 bookmark，支持“重新检查目录权限/重新选择目录”。
4. 迁移：导出到临时目录后用 `NSFileCoordinator` 协调写入外接目录；持有 security-scoped access 覆盖整个迁移任务；进度显示、失败原因可见。
5. 校验：最小一致性校验（文件存在、非空、可读、时长近似），作为“可删除”前置条件。
6. 删除：仅删除“最近一次迁移运行中迁移+校验成功”条目；权限收紧为必须完全访问（`.authorized`）。
7. 历史：持久化迁移运行与条目结果；支持从首页跳转查看最近运行详情。
8. 国际化：`en` + `zh-Hans`，默认随系统。
9. 回归：单元测试覆盖主链路 guardrail、排序、选中状态、历史落盘截断等边界（大库/大量选择）。

### 机测结论（你提供）
1. 真机测试通过：流程稳定、功能正常（MVP 最终截图已归档，见项目进度文档）。

### 已知技术债 / 风险（明确记录）
1. 视频大小读取当前用 `PHAssetResource` 的 KVC 读取 `fileSize`，不是公开 API 合约，未来 iOS 版本可能失效或不适合上架场景。
2. 外接盘行为在不同文件提供者/盘体上可能存在差异，当前方案优先确保“可用 + 错误可见 + 可重试”。

### Release 准备清单（完成情况）
1. CI：已加入 GitHub Actions（编译/测试）。
2. 工程生成：不追踪 `ClipDock.xcodeproj/`，用 `xcodegen generate` 生成。
3. 文档：PRD/Dev Log/Project Plan 已齐备，且记录关键问题与解决方案。
4. Beta/Preview：已创建 GitHub Release `v0.2.6-beta.1`（tag + release notes）。
