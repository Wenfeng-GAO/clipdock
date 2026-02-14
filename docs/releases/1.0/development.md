# ClipDock 1.0 开发文档（独立版本）

更新时间：2026-02-14

本文件只描述 **1.0** 版本的实现方案与验证范围，不与 MVP 文档混写。

## 1. 版本范围（产品已确认）

1. 单页形态：不新增 Tab，不提供 `History` 页面，不提供 `Settings` 页面。
2. 目标目录结构：平铺（不自动创建 YYYY-MM 子目录）。
3. 批量选择规则：按月份、最大 N。
4. 迁移策略：更稳（串行）。
5. 视觉方向：干净克制。

对应 PRD：`/Users/wenfeng/Documents/iphoneapp/docs/releases/1.0/product.md`

## 2. UI 设计（SwiftUI）

### 2.1 目标
1. 降低信息密度：把“目录/扫描/选择/迁移/删除”按流程从上到下排列，用户一眼知道下一步。
2. 大库可用：列表虚拟化、分页加载、异步 size 补齐不干扰操作。
3. 删除更克制：删除入口在迁移完成后出现，且仅在满足权限与校验条件时可用。

### 2.2 页面结构（单页）
当前实现为“卡片式单页 + 底部操作区”：

1. 目录卡
   - 已选目录、可写状态、`Choose` / `Recheck`。
2. 扫描与选择卡（Scan & Select）
   - `Scan Videos` CTA（当授权状态为 `notDetermined` 时会触发系统弹窗；拒绝时给出提示）。
   - 统计：视频数量、已选数量、已选总大小（best-effort）。
   - 入口：`Select All` / `Quick Filter` / `Clear`、`Show selected only`。
3. 列表卡（Video List）
   - 列表顶部提供排序：字段 `Date/Size`（segmented）+ 正/倒序按钮。
   - 列表行支持点选切换选择；size 异步补齐。
4. 底部操作区（sticky）
   - `Start Migration` / `Delete Originals`。
   - 迁移中：进度条 + completed/total + 当前文件名。
   - 迁移后：成功/失败摘要 + 失败列表入口。
   - 状态策略：迁移完成且可删时，Start 置灰，Delete 变为强调态；删除后 Delete 置灰。

### 2.3 弹层：快捷筛选（Quick Filter）
1. 按月份：按“年份 -> 月份”分组展示（DisclosureGroup），并支持多选月份。
2. Top-N：输入 N（20/50/100 快捷），基于本地可得 size 的 “largest first”。
3. 动作：`Cancel / Apply`，且 `Apply` 仅在用户设置了筛选条件时可用。

## 3. 后端实现方式（MVVM + Services）

### 3.1 总体策略
1. 保持 `SwiftUI + MVVM`。
2. 迁移继续串行执行，失败条目支持重试（复用现有迁移结果结构）。
3. 1.0 不对外暴露历史页面；迁移“结果摘要”只保留最近一次运行（内存态即可）。

### 3.2 关键代码位置（当前工程）
1. Home UI：`/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeView.swift`
2. Home VM：`/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeViewModel.swift`
3. 视频扫描/size：`/Users/wenfeng/Documents/iphoneapp/ClipDock/Services/PhotoLibrary/VideoLibraryService.swift`
4. 迁移：`/Users/wenfeng/Documents/iphoneapp/ClipDock/Services/Migration/VideoMigrationService.swift`
5. 删除：`/Users/wenfeng/Documents/iphoneapp/ClipDock/Services/Deletion/PhotoDeletionService.swift`

### 3.3 数据结构（建议新增）
1. `MonthKey`（Value Object）
   - `year: Int`、`month: Int`、`display: String`（如 `2026-02`）
2. `MonthSummary`
   - `key: MonthKey`
   - `count: Int`
   - `assetIDs: [String]`（可延迟加载，仅在 Apply 时取）

### 3.4 选择规则实现（建议新增 Service）
新增 `SelectionRulesService`（纯逻辑，可单测）：
1. `groupByMonth(videos) -> [MonthKey: [VideoAssetSummary]]`
2. `selectByMonths(keys, monthIndex) -> Set<assetID>`
3. `selectTopN(n, candidates) -> Set<assetID>`（candidates 为当前排序后的数组）

### 3.5 size 获取与 Top-N 边界
1. size 读取使用 public API，且 `isNetworkAccessAllowed=false`，不会触发 iCloud 下载。
2. Top-N 选择与大小排序不强制要求 size 全量完成；未知 size 统一视为“排序靠后”，并在 UI 里显示 `--`。
3. 1.0 为了让“大小排序”更确定，扫描完成后会后台预取全库本地 size（best-effort）。

### 3.6 迁移与删除
1. 迁移：保持“导出到临时目录 -> `NSFileCoordinator` 写入目标目录”，持有 security scope 覆盖整个迁移任务。
2. 删除：仅允许删除最近一次运行中“迁移+校验成功”的条目；且要求 Photos 权限为 `.authorized`（完全访问）。

## 4. 测试与验证（1.0）

### 4.1 自动化（单元测试）
测试目标：`ClipDockTests`

1. 选择规则
   - 按月份分组正确性（跨年、creationDate 缺失兜底、月排序）
   - 多月选择 union 行为正确（不丢不重）
   - Top-N：在不同排序模式下取前 N 的确定性
2. 大库边界
   - 5k 视频下 groupByMonth 时间/内存可接受（逻辑层）
3. 安全闸门
   - 无目录/不可写/无选择不允许迁移
   - 非完全访问不允许删除

回归命令（避免 DerivedData 锁冲突）：
1. `xcodegen generate`
2. `DERIVED=$(mktemp -d /tmp/ClipDockDerivedDataTest.XXXXXX) && xcodebuild ... -derivedDataPath \"$DERIVED\" test`

### 4.2 手工验证（真机）
1. 基础闭环：选择目录 -> 扫描 -> 规则选择（月份/Top-N）-> 迁移 -> 删除
2. 权限流：限制访问/拒绝/完全访问切换
3. 外设：拔盘、重插、目录权限失效与恢复
4. iCloud-only：size 显示 `--`、迁移时的提示与失败可见性
5. 目标目录：外接盘与“On My iPhone”目录都可用（方便 App Review 复现）

---

## 开发记录（1.0）

### 2026-02-13 - 规则选择（按月份 / Top-N）+ 去除 History 入口
1. 交付：
   - 新增规则选择服务 `SelectionRulesService`（按月份分组 + Top-N 选择）。
   - UI 增加 `By Month...` / `Top N...` 弹层入口（后续在 1.0 收敛为 `Quick Filter`）。
   - 移除 `History` 相关 UI 入口（按 1.0 形态要求）。
2. 关键文件：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Services/Selection/SelectionRulesService.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/RulePickers/MonthPickerView.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/RulePickers/TopNPickerView.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeViewModel.swift`
3. 验证：
   - `xcodebuild test`（Simulator）：新增 `SelectionRulesServiceTests`，总计 16 tests / 0 failure。

### 2026-02-13 - UI 收敛：迁移操作改为底部 Action Bar
1. 交付：
   - 将迁移/删除/结果摘要从列表 Section 移至底部 `safeAreaInset` Action Bar，减少页面信息密度。
   - 失败详情改为单独 sheet（可复制错误信息）。
2. 关键文件：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/MigrationActionBar.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeView.swift`
3. 验证：
   - `xcodebuild build`（iOS）通过。
   - `xcodebuild test`（Simulator）：16 tests / 0 failure。

### 2026-02-13 - Home UI 重构：卡片式单页 + 自定义列表
1. 背景：原首页使用 `List + Section`，整体更像“设置页”，信息密度高且不符合“干净克制”的方向。
2. 交付：
   - 首页改为 `ScrollView + HomeCard` 的卡片式布局：权限 / 外接目录 / 扫描 / 选择 / 列表，从上到下按流程排列。
   - `About` 改为右上角 `info` 按钮打开 sheet，减少主页面干扰。
   - 视频列表改为自定义 `LazyVStack`，仍支持“点选切换选择 + 异步补齐 size + Load More”。
3. 关键文件：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeView.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/Components/HomeCard.swift`
4. 验证：
   - `xcodebuild test`（Simulator）：16 tests / 0 failure。

### 2026-02-14 - UI 调整：去权限展示、合并扫描与选择、排序下沉到列表
1. 背景：根据真机反馈进一步“更稳、更克制”：减少不可控信息（权限展示）、减少卡片数量、把排序放在列表上下文里。
2. 交付：
   - 移除“相册权限卡”。扫描按钮会在 `notDetermined` 时触发系统授权弹窗；若已拒绝则提示用户去系统设置开启。
   - 合并“扫描视频 + 选择视频”为一张卡（Scan & Select），并在卡片内同时展示“视频数量 + 已选择数量”。
   - 排序控件移动到“视频列表”卡片顶部：字段 `Date/Size`（segmented）+ 正/倒序箭头按钮。
   - 列表默认展示 20 条，`Load More` 每次 +20。
3. 关键文件：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeView.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeViewModel.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Resources/en.lproj/Localizable.strings`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Resources/zh-Hans.lproj/Localizable.strings`
4. 验证：
   - `xcodebuild test`（Simulator）：16 tests / 0 failure。

### 2026-02-14 - Bugfix：大小排序依赖 Top-N 才正确
1. 现象：直接切换到“按大小排序”时排序不稳定/不正确；执行一次 `Top N` 选择后（触发全量 size 预取）才变正确。
2. 根因：此前 size 预取仅覆盖前 200 条，导致大库下 size 排序缺少足够的 size 数据。
3. 修复：
   - 扫描完成后自动后台预取“本地可得”的全部视频 size（不触发 iCloud 下载），保证 size 排序可用且更确定。
   - size 排序模式下也会兜底触发全量 size 预取。
4. 验证：
   - `xcodebuild test`（Simulator）：回归新增/更新 `HomeViewModelSortAndSizeTests` 覆盖扫描后全量 size 预取。

### 2026-02-14 - 选择体验：快捷筛选 + 取消/应用 + 已选总大小
1. 交付：
   - 合并“按月份选择 / 最大 N”入口为单一入口 `Quick Filter（快捷筛选）`。
   - 筛选弹窗按钮改为 `Cancel / Apply`；当未选择任何筛选条件时，`Apply` 不可用。
   - 首页展示“已选视频总大小”（基于本地可得 size，iCloud-only 条目会导致部分未知）。
   - `Clear` 在存在选择时视觉上更“亮”（启用态使用强调色）。
2. 关键文件：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeView.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/RulePickers/QuickFilterView.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeViewModel.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Resources/en.lproj/Localizable.strings`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Resources/zh-Hans.lproj/Localizable.strings`
3. 验证：
   - `xcodebuild test`（Simulator）：16 tests / 0 failure。

### 2026-02-14 - 视觉收敛：移除 Home 大标题
1. 交付：
   - Home 页面移除导航标题 “ClipDock”，减少无效占位，保留右上角 `info` 入口。
2. 关键文件：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/HomeView.swift`
3. 验证：
   - `xcodebuild test`（Simulator）：通过。

### 2026-02-14 - 快捷筛选：月份按年份分组（可折叠）
1. 交付：
   - `Quick Filter` 的月份列表按 `Year -> Months` 分组展示，支持展开/收起，缓解月份列表过长问题。
   - 新增单测覆盖长列表（6 年 * 12 月 + unknown）。
2. 关键文件：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/RulePickers/MonthSummaryGrouper.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/RulePickers/QuickFilterView.swift`
   - `/Users/wenfeng/Documents/iphoneapp/ClipDockTests/MonthSummaryGrouperTests.swift`
3. 验证：
   - `xcodebuild test`（Simulator）：通过。

### 2026-02-14 - 迁移操作条：完成后引导删除
1. 交付：
   - 迁移完成且存在可删条目时：`Start Migration` 置灰，`Delete Originals` 变为强调态（红色）。
   - 删除完成并触发 rescan 后：`Delete Originals` 置灰。
2. 关键文件：
   - `/Users/wenfeng/Documents/iphoneapp/ClipDock/Features/Home/MigrationActionBar.swift`
3. 验证：
   - `xcodebuild test`（Simulator）：通过。
