# SEAM-S6 — 备份导入 + 在线更新（S6）

基线：`feature/swift-2.0-settings @ f54a610`。结果分支：`feature/swift-2.0-backup`
（合腿在协调员 clone `standalone-app-2.0-s6-backup` 里以文件拷贝完成——
该 clone 被系统执行风险检查标记，git/preflight 由主 agent 在此执行）。
验证：细看代码 + 类型/引用逐项核对 + 括号平衡。未编译验证（无 Swift
工具链，按 chen 的规矩不打构建，等最终打包时验）；preflight 由主 agent
在合腿后跑（文件数期望已改为 145）。

## 三腿分工

- A 腿：备份引擎。`Services/Backup/`（`BackupEnvelope` / `BackupEngineCore` +
  `FileBackupEngine` / `ZipArchive`，手写 stored-ZIP + CRC32）。单个 .zip：
  `backup.json`（信封 + 全部 UserDefaults 值）+ `collections/<名>.json`（原字
  节）+ `files/<相对路径>`（壁纸、LX 脚本、下载成品、本地音乐、字体、录音、
  日志）。覆盖 S1 的 136 键 + 4 键族（直接复用 `MigrationStore` 映射表，不抄
  第二份）+ S5 新增键 + `settingsSectionExpanded_<id>` 族。
- B 腿：备份 + 更新 UI。`Features/My/BackupUpdateLogic.swift`（缝协议与纯
  逻辑，进 AppCore）+ `BackupUpdateViews.swift`（`BackupUpdateFlow` 单例、
  更新提示 sheet、alert）。设置页数据组加导出/导入备份、关于组加检查更新行
  + 已跳过版本取消行；我的页旧版数据提示的死路已接通导入。
- C 腿：更新检查器 + 跨代迁移测试。`Services/Update/`（`DefaultUpdateChecker`
  / `UpdateManifest` / `VersionCompare`，Flutter `compareSemver` 移植）+
  `Tests/UpdateTests/` + `Tests/MigrationCoreTests/CrossGenerationMigrationTests.swift`。

## 关键契约（S7 / 最终打包要用到）

- **Swift 5.0，completion handlers only**：工程 SWIFT_VERSION = 5.0，
  preflight 5e 禁 ` async ` 与 `(any `。任务书初版给 A/C 写了 async 签名
  是错的，B 腿发现、协调员已中断更正；三腿最终全是 completion-handler
  形式（`exportBackup(completion:)` / `checkForUpdate(completion:)`，主线程
  回调；“全部写完再报成功”靠 dispatch group，不是 await）。
- **缝的归属（同一类型只声明一次）**：`BackupEngine` protocol、
  `BackupImportReport`、`UpdateChecker` protocol、`UpdateCheckResult`、
  `.haoBackupImported` 归 B 的 `BackupUpdateLogic.swift`；A 的引擎是
  `BackupEngineCore`（静态实现）+ `FileBackupEngine: BackupEngine`；
  C 的检查器是 `DefaultUpdateChecker: UpdateChecker`。C 的
  `UpdateCheckSeam.swift`（B 的逐字副本）**合腿时已删**，不许带回。
- **备份格式**：单个 .zip；信封 `schema` 是形状版本（当前 1），
  `appVersion`/`appBuild` 导出时从 Bundle 读，永不硬编码；新版备份拒绝、
  旧版接受。导入：先校验信封 → 快照当前存储（`Documents/backup_snapshots/`）
  → 逐条写 → 逐项校验 → 失败全量回滚；坏键跳过、未知键隔离进
  `backup_unknown_keys.json`、merge 不是 replace；导入成功 post
  `.haoBackupImported`。**发布门：S6 的备份导入测试 + 跨代迁移测试全部
  通过之前，任何 version.json 里都不许出现 2.0.0**（本次未动任何 version.json，
  根 version.json 仍是 1.0.3/build 4）。
- **凭证永不进备份**：Emby apiKey 只进 Keychain；导出剥掉配置里的 apiKey
  并告警原文 `Emby 凭证未导出，需重新登录`；导入绝不写 Keychain，无凭证时
  报告 `embyCredentialsMissing = true`；LX 脚本密钥同样 Keychain-only。
  导出 zip 超 4 GiB 时拒绝写入（无 ZIP64），不是静默出坏包。
- **更新检查**：主源 shop `version.json`，失败重试一次后 fallback GitHub raw
  （本仓库根目录的 version.json，不再用 Gitee）；
  总限 15s（deadline，到时取消在途 task）；比较 version + build（同版高
  build 也提示）；跳过按 version+build（存 `skippedVersion`，Flutter 原键）；
  自动检查 20h 节流，戳（`lastUpdateCheckAt`，Flutter 原键）只在成功拉到
  manifest 后写，失败不消耗窗口，手动检查不移动自动窗口；`minOs` 必读，
  高于设备时只报 `requiresNewerOS`、绝不给安装按钮。`hao_last_update_check_date`
  是 2.0 新键，只作“上次检查”显示日期（手动/自动成功都写）。
- **导入后重读（协调员合腿时补的）**：`SettingsStore.reloadFromDefaults()` 与
  `ThemeStore.reloadFromDefaults()` 监听 `.haoBackupImported`（主线程回调），
  重读全部设置（init 里的读数原样保留一份在 reload 里，两处保持同步；
  读数留在 init 内联是因为 @Published 无默认值、Swift 不许在赋值前调方法）。
  Library stores 按需读盘，无需重读；跳过/节流状态按需读键，无需重读。
  接线在 `HAoStudioApp`：`BackupUpdateFlow.shared.engine = FileBackupEngine()`、
  `.checker = DefaultUpdateChecker()`，启动时一次自动检查（`checkAutoIfEnabled`，
  有新版则弹同一更新 sheet）。
- **两个比较器并存**：B 的 `UpdateCheckLogic.isNewer`（非数值段按 0）只被
  B 的测试调用；生产决策走 C 的 `VersionCompare`（Flutter 移植，非数值段
  按字符串比）。纯数值版本号两者结论一致；不许把 B 的用于生产判断。
- **测试**：BackupTests 14 个、UpdateTests 38 个、SettingsTests 新增 24 个
  （B 的纯逻辑）、MigrationCoreTests 新增 7 个（跨代迁移：136 命名键 + 9
  前缀族 + 2 忽略缓存键 + 3 未知键 = 150 键逐条断言）；SettingsUITests 新增
  4 个未接线，等 S7。**全部已写、未运行**（无 Swift 工具链）。

## 诚实局限

- 未编译验证，等最终打包时验。
- `live_recordings/` 与 `logs/` 在 Swift 侧尚无写入方：引擎只负责“有则打包”，
  落盘本身是遗留待接线项。导入快照保留在 `Documents/backup_snapshots/`，
  目前无清理入口。
- A 的 100 条计数（93 设置键 + 2 section 键 + 5 集合文件）未跑过，数错会
  loud fail（`XCTAssertEqual(total, 100)`），不会静默过。
- 导出分享是两步：点“导出”→ 导出完成 → 出现 ShareLink 行再点分享（SwiftUI
  无 UIKit 包装时无法自动弹出分享表）；导入进度是不定式转圈（导入 API 无
  进度回调）。
