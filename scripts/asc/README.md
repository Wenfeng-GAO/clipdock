# ClipDock App Store Connect 发布工具

> **⚠️ 不要在没有恒拙明确「提审」授权的情况下运行 `submit`（以及 `preflight --fix`）。**
> `submit` 会把版本推进到 Waiting for Review，`preflight --fix` 会改动线上 App Store Connect 的元数据。
> 两者都是对外可见、需要人工批准的写操作。没有明确授权时，只跑 `probe` 和 `--dry-run`。

一个只用 Python 标准库的 App Store Connect 发布脚本，把 2026-10-30 手动上架 ClipDock 1.1 时踩到的两个坑
写成了硬性前置条件。无需 `pip install`，macOS 自带的 `openssl` 就够。

- 位置：`scripts/asc/asc_release.py`
- 测试：`scripts/asc/test_asc_release.py`（纯函数，不联网）
- 要求：Python 3.9+，`openssl` 在 `PATH` 上

---

## 1. 它解决的两个坑（重要，请先读）

### 坑一：`APP_IPHONE_69` 不存在

`appStoreScreenshotSets.screenshotDisplayType` **没有** `APP_IPHONE_69` 这个值。
2026-10-30 真实报错：

```
409 ENTITY_ERROR.ATTRIBUTE.TYPE
'APP_IPHONE_69' is not a valid value for the attribute 'screenshotDisplayType'.
```

最大的合法 iPhone 值是 **`APP_IPHONE_67`**，它同时接受 **1320×2868**（6.9 寸）和 **1290×2796**（6.7 寸）。

所以本脚本**不猜、也不硬编码**：它会先读上一已发布版本（或任意已有版本）的截图集，
复用那边**已经存在**的 displayType。只有当 ASC 里一个 iPhone 截图集都找不到时，才退回
`FALLBACK_DISPLAY_TYPE = "APP_IPHONE_67"` 这个有文档记录的常量，**并打印警告**。
`APP_IPHONE_69` 永远不可能被选中。

### 坑二：不用空提交探针，409 只会给你一句没用的话

直接 `PATCH /v1/reviewSubmissions/{id}` 提交时，ASC 只返回：

```
409 STATE_ERROR.ENTITY_STATE_INVALID — ... please check associated errors to see why.
```

真正的清单在 **`meta.associatedErrors`** 里，而只有在 POST `reviewSubmissionItems` 失败时才会带出来。
所以 `preflight` 会：

1. 建一个一次性 submission（空 submission 无害，ASC 下次还会还给你同一个）；
2. POST 一个针对目标版本的 `reviewSubmissionItems`，读 409 里的 `meta.associatedErrors`；
3. 把**每一条** associated error 用人话打出来；
4. `--fix` 时自动修那两条确定安全的：
   - `builds.usesNonExemptEncryption = false`
   - `ageRatingDeclarations.socialMedia = false`
   **且仅当当前值是 null** 时才写；
5. 等截图 asset 变成 `COMPLETE`；
6. 重新探针，直到干净；只要还有一条没解决就**拒绝提交**并以非 0 退出。

1.1 那次真实探针就是这三条：`usesNonExemptEncryption`、`socialMedia`、截图还在 post-processing。
这三条原样保存在测试文件里的 JSON fixture 中。

### 附带一条：Sales key 读不了 builds

ClipDock 有两把 ASC key：

| 文件 | 角色 | 能干什么 |
| --- | --- | --- |
| `AuthKey_YYK7P6W893.p8` | App Manager | 能读 `/v1/builds`、能提审 |
| `AuthKey_7XL5564K84.p8` | Sales and Trends | **读不了** `/v1/builds` |

用错 key 会在 `/v1/builds` 上收到 403。脚本检测到这种情况会直接打印上面这条原因，
而不是让你自己去猜。key id / issuer id / 私钥一概不写进仓库，只从环境变量或参数读。

---

## 2. 认证

```bash
export ASC_ISSUER_ID="<team issuer uuid>"
export ASC_KEY_ID="<key id, 例如 YYK7P6W893>"
export ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_<key id>.p8"
```

也可以用参数覆盖：`--issuer` / `--key-id` / `--key-path`。参数优先于环境变量。

- 私钥只被 `openssl dgst -sha256 -sign` 读取，**不会**被打印、**不会**写盘。
- JWT 是 ES256：脚本用 `openssl` 签 DER，再把 DER 转成 `r||s` 原始 64 字节（ES256 要原始格式）。
- `--verbose` 下所有 token 都会被替换成 `<redacted>`。
- app id 默认是 ClipDock 的 `6759184867`，可用 `--app-id` 或 `ASC_APP_ID` 覆盖。

---

## 3. 子命令

所有子命令都接受 `--version`（例如 `1.1`）。全局参数放在子命令前后都可以。

### `probe`（只读，随时可跑）

打印 app 信息、所有 `appStoreVersions` 及其 `appStoreState` / `appVersionState`、
最近的 builds 及 `processingState`、现有 `reviewSubmissions` 及其 state。
带 `--version` 时还会显示目标版本：已挂的 build、各 locale 的 `whatsNew` 是否为空、已有截图集的 displayType。

```bash
python3 scripts/asc/asc_release.py probe --version 1.1
```

### `preflight`（空提交探针）

```bash
# 只看问题，不改任何东西
python3 scripts/asc/asc_release.py preflight --version 1.1

# 自动修两条安全项 + 等截图处理完 + 反复探针
python3 scripts/asc/asc_release.py preflight --version 1.1 --fix
```

退出码：`0` 干净；`3` 仍有未解决的 associated error；`2` 参数/凭据问题；`4` 接口异常。

相关参数：`--max-probes`（默认 3）、`--probe-interval`（默认 10 秒）、
`--wait-timeout`（等截图处理，默认 900 秒）、`--submission-id`（复用指定 submission）。

### `screenshots`（上传截图）

```bash
python3 scripts/asc/asc_release.py screenshots \
  --version 1.1 \
  --locale-dir en-US=./out/en \
  --locale-dir zh-Hans=./out/zh-Hans
```

- displayType 按上面「坑一」的逻辑复用已有的，`--display-type` 可强制覆盖。
- 每个 locale：找到（没有就创建）对应 displayType 的截图集 → **先清空旧截图** →
  按文件名数字顺序上传 → 等所有 asset `COMPLETE`。
- 上传流程：`POST /v1/appScreenshots` 预留拿 `uploadOperations` → 按每个操作的
  `offset`/`length` 切块 PUT → `PATCH` 提交 `uploaded: true` + MD5 校验和。
- 文件尺寸不符合所选 displayType 的已知规格时会打印警告（不中断）。

### `submit`（挂 build + 提审）

```bash
python3 scripts/asc/asc_release.py submit --version 1.1 --build 12 \
  --whats-new-file ./whats-new.md
```

- 先挂 build（已挂则跳过），可顺带同步各 locale 的 `whatsNew`。
- **提交前一定跑一次空提交探针；不干净就拒绝提交**（退出码 3）。
- `--skip-preflight` 存在但强烈不建议，用了会打印警告。
- 已经处于 `WAITING_FOR_REVIEW` / `IN_REVIEW` 等状态时直接返回成功，不会重复提交。

### `--dry-run`

对 `preflight` / `screenshots` / `submit` 都成立：只打印**确切的 HTTP 方法 + 路径 + 脱敏后的 body**，
不做任何写操作（只发 GET）。注意 `--dry-run` 下的 `preflight` 不会真的探针，
所以它只告诉你「本来会发什么」，不会给出「干净/不干净」的结论。

---

## 4. `--whats-new-file` 格式

两种都行，按 locale 分段：

```markdown
## en-US
Improved the photo picker bottom scrim so labels stay readable in light and dark mode.

## zh-Hans
优化相册选择器底部遮罩，深色/浅色下文字更清晰。
```

```ini
en-US = Improved the photo picker bottom scrim.
zh-Hans = 优化相册选择器底部遮罩。
```

---

## 5. 1.1 实战 runbook（worked example）

这是 2026-10-30 实际走完的流程，按顺序照做即可。

### 0. 准备

```bash
git checkout main && git pull
export ASC_ISSUER_ID="<issuer>"
export ASC_KEY_ID="YYK7P6W893"                                   # App Manager key，不是 Sales key
export ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_YYK7P6W893.p8"
```

### 1. 改版本号

`project.yml` 里把 `MARKETING_VERSION` 改成新版本、`CURRENT_PROJECT_VERSION` 加一
（1.1 那次是 `1.1` / `12`），然后重新生成工程：

```bash
xcodegen generate
```

### 2. Archive + 上传

Xcode 里：选中 `ClipDock` scheme → Product → Archive → Distribute App →
App Store Connect → Upload。命令行等价写法：

```bash
xcodebuild -project ClipDock.xcodeproj -scheme ClipDock \
  -destination 'generic/platform=iOS' -archivePath build/ClipDock.xcarchive archive
xcodebuild -exportArchive -archivePath build/ClipDock.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
# 或直接：xcrun altool --upload-app -f build/export/ClipDock.ipa -t ios \
#           --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```

上传完等 ASC 处理完（`processingState == VALID`）：

```bash
python3 scripts/asc/asc_release.py probe --version 1.1
```

### 3. 建版本（如果 `probe` 说没有 1.1）

1.1 那次是脚本建的。现在如果版本不存在，先在 ASC 网页里
「+ 版本或平台」新建 iOS 1.1，或者用 API：

```
POST /v1/appStoreVersions
{"data":{"type":"appStoreVersions","attributes":{"platform":"IOS","versionString":"1.1"},
 "relationships":{"app":{"data":{"type":"apps","id":"6759184867"}}}}}
```

`preflight` 发现版本不存在会以退出码 2 明确报错，不会自己乱建。

### 4. 跑空提交探针

```bash
python3 scripts/asc/asc_release.py preflight --version 1.1
```

第一次跑大概率会看到三条 associated error（1.1 的真实输出）：

```
1/3. ENTITY_ERROR.ATTRIBUTE.REQUIRED
    resource: /v1/builds/b246d0d7-...
    detail:   You must provide a value for the attribute 'usesNonExemptEncryption'
    action:   auto-fix usesNonExemptEncryption = False ...

2/3. ENTITY_ERROR.ATTRIBUTE.REQUIRED
    resource: .../ageRatingDeclaration
    detail:   You must provide a value for the attribute 'socialMedia'
    action:   auto-fix socialMedia = False ...

3/3. STATE_ERROR.ENTITY_STATE_INVALID
    resource: /v1/appScreenshots/...
    detail:   The screenshots are still processing ...
    action:   wait for screenshot assets to reach COMPLETE, then re-probe
```

加上 `--fix` 让它自己处理并重探：

```bash
python3 scripts/asc/asc_release.py preflight --version 1.1 --fix
```

### 5. 上传截图

> 截图**不进仓库**（`docs/app-store/screenshots/` 在 `.gitignore` 里），放在本地任意目录即可。
> 1.1 那批图当时在本机 `/home/box/design-backup/clipdock-1.1-store/out/` 下，
> 结构是 `6.9-1320x2868/{en,zh-Hans}` 和 `6.7-1290x2796/{en,zh-Hans}`，每个目录 `01..05.png`。

一个 locale 只能挂一个 displayType，所以**同一次运行里每个 locale 只用一组同尺寸的图**。
`APP_IPHONE_67` 两种尺寸都收（1320×2868 / 1290×2796），二选一即可：

```bash
# 用 6.9" 那批（1320x2868）
python3 scripts/asc/asc_release.py screenshots --version 1.1 \
  --locale-dir en-US=/path/to/out/6.9-1320x2868/en \
  --locale-dir zh-Hans=/path/to/out/6.9-1320x2868/zh-Hans
```

脚本会复用现有 displayType（1.1 那次最终是 `APP_IPHONE_67`），先清空旧图再上传，并等 asset `COMPLETE`。

> 想只看计划、不真上传，加 `--dry-run`：它会打印将要创建的截图集、每个文件的 MD5
> 和每次 PUT 的字节区间，但一张图都不发。

### 6. 再探针，然后提审

```bash
python3 scripts/asc/asc_release.py preflight --version 1.1 --fix   # 必须 exit 0
python3 scripts/asc/asc_release.py submit --version 1.1 --build 12 \
  --whats-new-file ./whats-new.md
```

`submit` 内部还会再探针一次；不干净就停下并让你回去修。真正写完会打印：

```
SUBMITTED <submission id> state=WAITING_FOR_REVIEW submittedDate=...
```

### 7. 收尾

```bash
python3 scripts/asc/asc_release.py probe --version 1.1
```

确认版本是 `WAITING_FOR_REVIEW`、build 已挂上。

---

## 6. 本地测试

```bash
python3 -m unittest discover -s scripts/asc -p 'test_*.py' -v
```

测试全部是纯函数，不联网、不需要 key，在干净的 Linux 上就能过。覆盖：

- DER → 原始 `r||s` 签名（72 字节真实向量，断言两半各 32 字节）；
- JWT header/payload 的 base64url 正确性（无 padding、无 `+`/`/`）；
- displayType 选择（只有 `APP_IPHONE_67`、一个都没有、iPad/Watch 混入、`APP_IPHONE_69` 必须被忽略）；
- MD5 校验和；
- uploadOperations 多块切片（乱序 offset、缺 length、尾块不足）；
- 真实 409 里的 associated error 展平（含我们实际撞到的三类）。

---

## 7. 设计取舍

- **只用标准库**：不引入 `cryptography` / `PyJWT`，签名交给系统 `openssl`，所以任何有 openssl 的机器都能跑。
- **可复用**：app id 可覆盖，版本号 / build 号 / locale 目录 / release notes 全部参数化，没有写死的 ClipDock id。
- **保守**：只有两条确定安全的属性会被自动写，且仅在当前值为 null 时；其余一律只报告不动手。
- **不碰代码**：本目录只加脚本、测试和文档，不改 Swift、`project.yml`、`.github/workflows/`。
