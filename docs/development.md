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
