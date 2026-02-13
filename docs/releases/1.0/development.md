# ClipDock 1.0 开发文档（独立版本）

更新时间：2026-02-13

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
建议从现有 `List + 多 Section` 调整为“顶部状态卡 + 列表 + 底部操作区”的结构：

1. 顶部状态卡（2 张卡片）
   - 目录卡：已选目录、可写状态、`Choose` / `Recheck` 按钮
   - 权限卡：相册权限状态、`Grant` 按钮
2. 扫描与排序卡
   - `Scan Videos` CTA
   - 排序 `Date/Size`（保持 segmented）
   - `Loading sizes...` 次级提示
3. 选择卡
   - 手动选择提示 + 统计（已选数量）
   - 规则选择入口：
     - `By Month...`（弹层 Month Picker）
     - `Top N...`（弹层 N 输入 + 应用）
   - `Show selected only`、`Select all`、`Clear`
4. 列表（虚拟化）
   - 仅负责展示与勾选，不承载迁移/删除按钮
5. 底部操作区（sticky）
   - Primary：`Start Migration`
   - Secondary：`Delete Migrated Originals`（仅在迁移完成且 deletable>0 时可用）
   - Progress：进度条 + 当前文件名（迁移中）
   - 结果摘要：成功/失败数（迁移后）

### 2.3 弹层 A：按月份选择（Month Picker）
1. 数据来源：扫描完成后按 `creationDate` 生成 `YYYY-MM` 分组。
2. 展示：月份列表（YYYY-MM）+ 视频数量；支持多选月份。
3. 动作：`Apply` 将所选月份的全部视频加入选中集合；`Clear` 清空月份选择。

### 2.4 弹层 B：最大 N（Top-N Picker）
1. 输入：N（快捷按钮 20/50/100 + 自定义输入）。
2. 规则：对“当前排序结果”取前 N（如果启用“仅看已选”，则对过滤后的列表取前 N）。
3. 说明：当排序为 `Size` 时，未知 size 的视频排在底部，Top-N 默认只会命中已知 size 的条目。

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
   - UI 增加 `By Month...` / `Top N...` 弹层入口。
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
