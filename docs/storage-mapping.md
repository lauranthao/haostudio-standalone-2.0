# HAo Studio 2.0 — Flutter 存储 → Swift 存储映射

2.0 不再用 Hive。设置进 UserDefaults，集合/索引用 Documents 下的 Codable JSON
文件。键名尽量沿用 Flutter 的 Hive 键名，只换存储机制，这样对照与迁移都有
据可查。来源：Flutter build 31（`lib/core/storage/hive_store.dart:44-554`、
`lib/core/theme/theme_controller.dart`、`lib/core/storage/local_paths.dart`、
`lib/core/theme/appearance_store.dart`，HEAD 2ef902b，1.1.6+31；另有未进
`HiveKeys` 的字面量键，见各域表内出处）。

**覆盖率（S1，2026-11-23；2026-11-25 b49fix2 P1-3 后更新；2026-11-26 b49fix19 P2-1 后更新；2026-11-26 b49fix20 D22-15 修正）：122 行——117 个具名键 + 4 个键族 + 1 个 2.0 新增键
（`haoVodProg:`、`hao_daily_YYYY-MM-DD`、`hao_listen_YYYY-MM`、
`hao_play_url_cache:`），全部有明确去向，覆盖率 100%。其中迁移 120 行；
1 个键族（`hao_play_url_cache:`）按设计不迁移：1 小时 TTL 的签名 URL 缓存，
2.0 首次启动时已过期。未知键（不在表里）不丢弃，隔离进
`Documents/migration_unknown_keys.json`。可执行版见
`ios/HAoStudio/Storage/MigrationStore.swift` 的 `mappings` /
`prefixRules` / `ignoredPrefixes`，与本表逐行一致。**

**更新（2026-11-25，b49fix2 P1-3）：以下 25 个键已从 `MigrationStore.mappings`
删除——app 只迁移它们、没有任何代码读取它们（只迁不读）：`preferResolution`、
`liveCrashStage`、`engineSectionExpanded`、`playbackSectionExpanded`、
`hao_feature_cover_plaza`、`hao_feature_cover_charts`、`hao_music_bookmarks`、
`hao_music_sources`、`hao_music_queue_memory`、`hao_sa_xh_device`、
`hao_wallpaper_v115_off_once`、`hao_tabbar_accent_presets`、
`hao_custom_font_family`、`hao_custom_font_name`、`hao_custom_font_path`、
`hao_vod_playback_rate`、`hao_vod_sleep_custom_minutes`、
`hao_vod_sleep_episode_count`、`hao_vod_subtitle_delay`、
`hao_vod_metadata_overrides`、`hao_emby_home`、`hao_live_hist_retention_days`、
`hao_live_hidden_platforms`、`hao_live_clock_corner`、`hao_live_volume_boost_pct`。
本表下方涉及这 25 个键的行已随 b49fix18 D-2 删除，本段所列即历史记录；快照里带这些键时数据
不丢，隔离进 `migration_unknown_keys.json`，以后有真实读取方时可重新加回映射。
（`hao_sa_xh_device` 不是 UserDefaults 键——解析器直接读
`hao_sa_xh_device.json` 文件，删行不影响功能。）当前映射表为 117 个具名键
（136 − 25 删 + 1 增 `hao_sa_video_applied` + 5 增 b49fix19 P2-1：`downloadTasks`、
`hao_fav_playlists`、`hao_fav_albums`、`hao_fav_artists`、`hao_daily_pool`），连同 4 个键族 + 1 个 2.0 新增键共 122 行。**

## 规则（铁律 7）

- 只存相对名：文件索引里存 `<subdir>/<file>`，绝不存绝对路径。iOS 每次重装都
  换容器 UUID，绝对路径会死；加载时先修后删，删前必须重扫目录（见
  `ios/HAoStudio/Storage/LocalStore.swift` 的 `LocalFileIndex`）。
- 旧绝对路径条目：加载时按 Flutter `LocalPaths` 同样的三级顺序解析——
  （1）绝对路径仍存在则直接用；（2）`<当前 Documents>/<subdir>/<basename>`；
  （3）都没有才算丢失；丢失前先重扫目录，磁盘上有同名文件就保留。
- 损坏的索引文件不许让启动崩溃：解码失败返回默认值（`LocalStore.loadCollection`）。
- 键名即契约，改名即丢数据：Swift 键名沿用 Flutter 键名，只换存储机制。
- 凭证只进 Keychain：Emby apiKey 进 Keychain，不进 UserDefaults/JSON/备份。

## 设置：Hive box `app_settings` → UserDefaults

### 播放 / 更新

| Flutter Hive 键 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `videoPlayerKey` | String，`mpv` | UserDefaults 同名键 | 2.0 默认内核按 chen 2026-11-23 决定走能力分流，见方案 §四；音乐永远 AVPlayer，不走这个键 |
| `hapticsEnabled` | bool，`true` | UserDefaults 同名键 | 触感反馈总开关 |
| `audioMixWithOthers` | bool，`false` | UserDefaults 同名键 | 与其他音频同时播放 |
| `autoResumeLastPlayback` | bool，`false` | UserDefaults 同名键 | 启动自动续播，只读杀后台时存的进度 |
| `skippedVersion` | String，`''` | UserDefaults 同名键 | 在线更新已跳过的版本 |
| `lastUpdateCheckAt` | int，`0` | UserDefaults 同名键 | 上次更新检查时间戳 |
| `autoUpdateCheck` | bool，`true` | UserDefaults 同名键 | 启动时自动检查更新 |

### 主题 / 外观

| Flutter Hive 键 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `haoThemeId` | String，`appleGlass` | UserDefaults 同名键 | `ThemeStore.themeKey`，值同为主题 rawValue |
| `haoThemeMode` | String，`system` | UserDefaults 同名键 | `ThemeStore.modeKey`，`system` / `light` / `dark` |
| `hao_wallpaper_enabled` | bool，`false` | UserDefaults 同名键 | 壁纸开关 |
| `hao_wallpaper_paths` | JSON 字符串，相对名列表 | `Documents/hao_wallpaper_paths.json` | 壁纸文件在 `wallpapers/`，按相对名重扫重建索引 |
| `hao_wallpaper_current` | String，`''` | UserDefaults 同名键 | 当前壁纸相对名 |
| `hao_bgcolor_enabled` | bool，`false` | UserDefaults 同名键 | 自定义背景色开关 |
| `hao_bgcolor_hex` | String，`''` | UserDefaults 同名键 | `#RRGGBB`，空即无 |
| `hao_tabbar_accent` | int ARGB，无默认值 | UserDefaults 同名键 | 底栏选中色；缺失即用主题自带强调色 |

### 音乐

| Flutter Hive 键 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `musicQuality` | String，`hires` | UserDefaults 同名键 | 目标音质，保留到下一首 |
| `musicPlazaPf` | String，`wy` | UserDefaults 同名键 | 音乐广场首选平台 |
| `musicSpeed` | double，`1.0` | UserDefaults 同名键 | 倍速 0.6–2.0 |
| `musicSearchPlatform` | String，`wy` | UserDefaults 同名键 | 搜索单平台胶囊，`wy` / `tx` / `kg` / `kw` |
| `curListId` | String，`''` | UserDefaults 同名键 | 当前歌单 id |
| `playMode` | String，`seq` | UserDefaults 同名键 | `seq` / `loop` / `one` / `shuffle` / `once` |
| `musicPlaylistsExpanded` | bool，`true` | UserDefaults 同名键 | 我的歌单区展开状态 |
| `musicRecentExpanded` | bool，`true` | UserDefaults 同名键 | 最近播放区展开状态 |
| `musicSleepCustomMinutes` | int，`30` | UserDefaults 同名键 | 睡眠定时自定义分钟，1–720 |
| `hao_music_normalization_enabled` | bool，`false` | UserDefaults 同名键 | 音量归一化开关 |
| `hao_music_normalization_strength` | int，`1` | UserDefaults 同名键 | 归一化强度 0–2 |
| `hao_music_fade_enabled` | bool，`true` | UserDefaults 同名键 | 淡入淡出开关；字面量键，未进 `HiveKeys` |
| `hao_music_lyric_offset_ms` | int，`0` | UserDefaults 同名键 | 歌词偏移毫秒，±5000；字面量键 |
| `hao_music_lyric_show_translation` | bool，`true` | UserDefaults 同名键 | 歌词显示译文；字面量键 |
| `hao_music_playback_cache_enabled` | bool，`true` | UserDefaults 同名键 | 边播边缓存开关；字面量键（`playback_cache.dart:31`） |
| `hao_lists` | JSON 字符串，歌单列表 | `Documents/hao_lists.json` |  |
| `hao_fav` | JSON 字符串，收藏歌曲 | `Documents/hao_fav.json` | 每条含完整歌曲 JSON；旧版仅 key 的条目仍可读 |
| `hao_recent` | JSON 字符串，上限 100 | `Documents/hao_recent.json` | 最近播放 |
| `hao_listen` | JSON 字符串，上限 3000 | `Documents/hao_listen.json` | 旧版单表收听记录，已冻结只读；新分片见 `hao_listen_YYYY-MM` 键族 |
| `hao_music_search_hist` | JSON 字符串，上限 20 | `Documents/hao_music_search_hist.json` | 音乐搜索历史 |
| `hao_cover_cache` | JSON 字符串，上限 500 | `Documents/hao_cover_cache.json` | 封面 URL 缓存 |
| `hao_lyrics` | JSON 字符串，上限 100 | `Documents/hao_lyrics.json` | 歌词缓存 |
| `musicQueue` | JSON 字符串 | `Documents/musicQueue.json` | 播放队列 `{songs, index}` |
| `musicDownloads` | JSON 字符串 | `Documents/musicDownloads.json` | 已下载歌曲；文件在 `music_downloads/` |
| `downloadTasks` | JSON 字符串 | `Documents/downloadTasks.json` | 下载任务（DownloadEngine 持久化状态）；整档写入。b49fix19 P2-1 新增映射，Route B 此前收不到此键。 |
| `musicResume` | JSON 字符串 | `Documents/musicResume.json` | 断点续播 `{identityKey: 秒}`，只在杀后台时写。b49fix17 P1-4：此为 dict 形狀——舊的遷移 fixture 曾誤以 list `[{"id":"x"}]` 抽樣它（見 `simulate_upgrade.py`／`CrossGenerationMigrationTests.swift` 的修正），2.0 的 `resumeMap()` 也只認 dict；Route B 匯入時按 dict overlay 合併。 |
| `fmDislikedIds` | JSON 字符串 | `Documents/fmDislikedIds.json` | 私人 FM 不喜欢的歌曲 id |
| `hao_fav_playlists` | JSON 字符串 | `Documents/hao_fav_playlists.json` | 收藏的歌单 id 列表；string list 合并。b49fix19 P2-1 新增映射，Route B 此前收不到此键。 |
| `hao_fav_albums` | JSON 字符串 | `Documents/hao_fav_albums.json` | 收藏的专辑列表；按 id+name 去重合并。b49fix19 P2-1 新增映射，Route B 此前收不到此键。 |
| `hao_fav_artists` | JSON 字符串 | `Documents/hao_fav_artists.json` | 收藏的艺人列表；按 id+name 去重合并。b49fix19 P2-1 新增映射，Route B 此前收不到此键。 |
| `hao_music_loudness_cache` | JSON 字符串，上限 200 | `Documents/hao_music_loudness_cache.json` | 响度缓存 `{identityKey: LUFS}`，丢了只影响第二遍起归一化冷启动 |
| `hao_local_music` | JSON 字符串 | `Documents/hao_local_music.json` | 本地音乐索引；文件在 `local_music/` |
| `hao_daily_pool` | JSON 字符串 | `Documents/hao_daily_pool.json` | 每日推荐候选池（100 条，7 天剪枝）；dict 合并。b49fix19 P2-1 新增映射，Route B 此前收不到此键。 |
| `hao_resolver_speed` | JSON 字符串 | `Documents/hao_resolver_speed.json` | 解析器测速 `{源: {avg, fails, cooled}}`；字面量键 |

### 影视 / 视频

| Flutter Hive 键 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `hao_video_auto_next` | bool，`true` | UserDefaults 同名键 | 自动连播下一集 |
| `hao_vod_double_tap_seconds` | int，`10` | UserDefaults 同名键 | 双击快进秒数，5/10/15/30/60 |
| `hao_vod_dialogue_boost` | bool，`false` | UserDefaults 同名键 | 对白增强，仅 MPV |
| `hao_vod_spoiler_hide_synopsis` | bool，`false` | UserDefaults 同名键 | 防剧透：隐藏简介 |
| `hao_vod_spoiler_blur_unwatched` | bool，`false` | UserDefaults 同名键 | 防剧透：模糊未看海报 |
| `hao_vod_audio_only` | bool，`false` | UserDefaults 同名键 | 纯音频后台模式 |
| `hao_vod_video_fit` | String，`auto` | UserDefaults 同名键 | 画面比例，`auto` / `fill` / `cover` |
| `hao_vod_super_resolution` | bool，`false` | UserDefaults 同名键 | Anime4K 超分，仅 MPV，仅 VOD |
| `hao_vod_skip_intro_mode` | String，`off` | UserDefaults 同名键 | 跳过片头，`off` / `manual` / `auto3s` / `autoNow` |
| `hao_vod_interpolation` | bool，`false` | UserDefaults 同名键 | 插帧，仅 MPV，仅 VOD；与超分、SDR→HDR 互斥 |
| `hao_vod_sdr_to_hdr` | bool，`false` | UserDefaults 同名键 | SDR 转 HDR，仅 MPV，仅 VOD；与超分、插帧互斥 |
| `hao_vod_subtitle_font_size` | String，`medium` | UserDefaults 同名键 | 字幕字号，`small` / `medium` / `large` |
| `hao_vod_subtitle_color` | String，`white` | UserDefaults 同名键 | 字幕颜色，`white` / `yellow` / `cyan` |
| `hao_vod_subtitle_position` | String，`bottom` | UserDefaults 同名键 | 字幕位置，`bottom` / `middle` / `top` |
| `hao_danmaku_occlusion_avoidance` | bool，`false` | UserDefaults 同名键 | 弹幕人物遮挡避让，仅 MPV |
| `hao_vod_dv_p8_downgrade` | bool，`true` | UserDefaults 同名键 | 杜比视界 P8 降级 HDR |
| `hao_low_memory_mode` | String，`auto` | UserDefaults 同名键 | 低内存模式，`auto` / `always` / `never`；旧 bool 键无代码迁移，只认 String，其余回 `auto` |
| `hao_douban_no_suggest` | bool，`false` | UserDefaults 同名键 | 豆瓣联想禁用标志（连续失败 3 次后置位） |
| `hao_sa_video_rev` | int，`0` | UserDefaults 同名键 | CMS 默认源修订号；用户删掉的源永不复活 |
| `hao_sa_video_applied` | JSON 字符串，字符串数组 | UserDefaults 同名键 | CMS 默认源已应用集合（URL 字符串数组）；`CmsClient.appliedKey`，用于区分用户删除与上游删除的默认源；b49fix2 新增的唯一映射行 |
| `hao_video_tab_mode` | String，`cms` | UserDefaults 同名键 | 影视 tab 当前页，`cms` / `emby` |
| `hao_video_category_prefs` | JSON 字符串 | `Documents/hao_video_category_prefs.json` | 影视分类显示/隐藏/重排 `{hidden, order}` |
| `hao_vod_skip_intro_durations` | JSON 字符串 | `Documents/hao_vod_skip_intro_durations.json` | 每集跳过片头秒数 `{标题\|集名: 秒}` |
| `hao_video_home` | JSON 字符串 | `Documents/hao_video_home.json` | 影视首页缓存 |
| `hao_video_hist` | JSON 字符串，上限 20 | `Documents/hao_video_hist.json` | 影视观看历史 |
| `hao_video_fav` | JSON 字符串 | `Documents/hao_video_fav.json` | 影视收藏 |
| `hao_video_search_hist` | JSON 字符串，上限 20 | `Documents/hao_video_search_hist.json` | 影视搜索历史 |
| `hao_douban_detail` | JSON 字符串，上限 200 | `Documents/hao_douban_detail.json` | 豆瓣详情缓存 |
| `hao_douban_idmap` | JSON 字符串，上限 200 | `Documents/hao_douban_idmap.json` | 豆瓣标题→id 映射缓存 |
| `hao_sa_video` | JSON 字符串 | `Documents/hao_sa_video.json` | CMS 影视源列表；至少保留一个源 |
| `hao_emby_config` | JSON 字符串 | `Documents/hao_emby_config.json`（去 apiKey）+ Keychain `emby-api-key` | Emby 配置 `{baseUrl, apiKey, userId, enabled, movieLibraryId, tvLibraryId}`；apiKey 只进 Keychain，文件里不留 |
| `haoVodProg:<source>:<vodId>` | 键族，double 秒数 | `Documents/haoVodProg.json`（合并文件） | 每集断点续播，上限 200 条；只计 >10 秒且距片尾 ≥30 秒的位置 |

### 直播

| Flutter Hive 键 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `hao_live_sources` | JSON 字符串 | `Documents/hao_live_sources.json` | 启用的直播平台，5 个中至少保留一个 |
| `hao_live_hist` | JSON 字符串 | `Documents/hao_live_hist.json` | 直播观看历史，默认上限 50 |
| `hao_live_hist_limit` | int，`50` | UserDefaults 同名键 | 直播历史上限，0 = 不限 |
| `hao_live_follows` | JSON 字符串 | `Documents/hao_live_follows.json` | 直播关注 |
| `hao_live_search_hist` | JSON 字符串，上限 20 | `Documents/hao_live_search_hist.json` | 直播搜索历史 |
| `hao_live_cellular_downgrade` | bool，`true` | UserDefaults 同名键 | 移动网自动降档；字面量键 |

### 弹幕

| Flutter Hive 键 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `hao_danmaku_enabled` | JSON 字符串 | `Documents/hao_danmaku_enabled.json` | 分平台弹幕开关 `{siteId: bool}` |
| `hao_danmaku_font_size` | double，`14` | UserDefaults 同名键 | 弹幕列表字号，12–20 |
| `hao_dm_block` | JSON 字符串 | `Documents/hao_dm_block.json` | 弹幕屏蔽列表 `{id, text, kind}`，kind 为 `word` / `user` |
| `hao_danmaku_list_style` | String，`compact` | UserDefaults 同名键 | 聊天列表样式，`compact` / `card` |
| `hao_danmaku_list_spacing` | String，`standard` | UserDefaults 同名键 | 聊天列表行距，`compact` / `standard` / `loose` |
| `hao_danmaku_show_names` | bool，`true` | UserDefaults 同名键 | 聊天列表显示发送者名 |
| `hao_danmaku_similarity` | bool，`true` | UserDefaults 同名键 | 相似弹幕过滤开关 |
| `hao_danmaku_similarity_threshold` | int，`85` | UserDefaults 同名键 | 相似度阈值 0–100 |
| `hao_danmaku_block_emote` | bool，`false` | UserDefaults 同名键 | 屏蔽纯表情弹幕 |
| `hao_danmaku_block_long` | bool，`false` | UserDefaults 同名键 | 屏蔽超长弹幕 |
| `hao_danmaku_block_long_len` | int，`30` | UserDefaults 同名键 | 超长上限字符数，10–100 |
| `hao_danmaku_douyu_bot` | bool，`false` | UserDefaults 同名键 | 斗鱼疑似机器消息过滤 |
| `hao_danmaku_opacity` | double，`1.0` | UserDefaults 同名键 | 弹幕列表文字不透明度，0.3–1.0 |
| `hao_danmaku_area` | String，`full` | UserDefaults 同名键 | 全屏飘弹幕区域，`full` / `half` / `third` |
| `hao_danmaku_stroke` | bool，`true` | UserDefaults 同名键 | 飘弹幕描边开关 |
| `hao_danmaku_stroke_width` | double，`1.0` | UserDefaults 同名键 | 飘弹幕描边宽度，0.5–2.0 |
| `hao_danmaku_speed` | double，`1.0` | UserDefaults 同名键 | 飘弹幕速度倍率，0.5–2.0；不是播放倍速 |
| `hao_danmaku_max_count` | int，`80` | UserDefaults 同名键 | 弹幕最大条数，20–200 |
| `hao_danmaku_color_mode` | String，`uniform` | UserDefaults 同名键 | 弹幕颜色模式，`uniform` / `platform` |

### LX 脚本

| Flutter Hive 键 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `hao_lx_disabled` | JSON 字符串 | `Documents/hao_lx_disabled.json` | 禁用的脚本 id 列表；缺失即全部启用 |
| `hao_lx_explicit_enabled` | JSON 字符串 | `Documents/hao_lx_explicit_enabled.json` | 显式启用的脚本 id 列表 |
| `hao_lx_custom` | JSON 字符串 | `Documents/hao_lx_custom.json` | 用户自加脚本 `{id, name, url, code, addedAt}` |
| `hao_lx_deleted_bundled` | JSON 字符串 | `Documents/hao_lx_deleted_bundled.json` | 已删内置脚本 id；删掉的永不复活 |
| `hao_lx_order` | JSON 字符串 | `Documents/hao_lx_order.json` | 脚本手动排序，排前先试 |

### 均衡器

| Flutter Hive 键 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `hao_eq_enabled` | bool，`false` | UserDefaults 同名键 | 均衡器开关 |
| `hao_eq_band_gains` | 10 项 double 列表，全 0 | UserDefaults 同名键 | 10 段增益 dB |
| `hao_eq_preset` | String，`flat` | UserDefaults 同名键 | 选中预设 id |
| `hao_eq_custom_name` | String，`''` | UserDefaults 同名键 | 选中自定义预设名，空即无 |
| `hao_eq_preamp` | double，`0` | UserDefaults 同名键 | 前级增益 dB |
| `hao_eq_custom_presets` | JSON 字符串 | `Documents/hao_eq_custom_presets.json` | 自定义预设 `{name, gains[10], preamp}` |
| `hao_eq_autoeq_name` | String，`''` | UserDefaults 同名键 | AutoEq 选择；字面量键，未进 `HiveKeys` |

### 键族（动态键，按前缀归并）

| Flutter Hive 键族 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `hao_daily_YYYY-MM-DD` | JSON 字符串 | `Documents/hao_daily.json`（合并文件） | 每日推荐缓存，按天一个键；b49fix19 P2-7：合并时日内逐歌合并去重（live 在前），不再整日覆写——「导入是合并」在日粒度上亦成立；快照键名保留为条目键 |
| `hao_listen_YYYY-MM` | JSON 字符串 | `Documents/hao_listen.json`（合并文件） | 收听记录按月分片，每片上限 3000；与冻结的旧 `hao_listen` 单表合并后上限 3000 |
| `hao_play_url_cache:<song\|platform\|quality>` | 键族 | 不迁移 | 播放 URL 缓存，1 小时 TTL，签名 URL；2.0 首次启动时已过期，丢了无影响 |

### 2.0 新增键（无 Flutter 对应，不迁移）

| Swift 键 | 类型 / 默认 | Swift 位置 | 备注 |
|---|---|---|---|
| `hao.audio.targetQuality` | String | `PlaybackCoordinator.targetQualityKey`（UserDefaults） | 2.0 新增目标音质；低一档播出时不覆盖它 |

## 集合/索引：Hive 同名数据 → Documents 下 JSON 文件

Flutter 侧这些集合原来存在 Hive box 里、值是相对名（`local_paths.dart` 已改
为相对名存储）；2.0 直接用 JSON 文件，文件名即集合名，内容为相对名数组
（`[StoredFileRef]`，见 `LocalStore.swift`）。

| Flutter 集合（子目录） | Swift JSON 文件 | 说明 |
|---|---|---|
| 本地音乐 `local_music/` | `Documents/local_music.json` | 导入的本地音乐文件索引 |
| 下载 `music_downloads/` | `Documents/downloads.json` | 下载文件索引 |
| 壁纸 `wallpapers/` | `Documents/wallpapers.json` | 自定义壁纸索引（`appearance_store.dart` 的 `kWallpaperSubdir`） |
| 自定义字体文件 `fonts/` | `Documents/fonts.json` | 用户安装的字体文件索引（后续 slice） |
| 歌单/收藏 | `Documents/favourites.json` | 点赞只存本地（无登录，不同步平台账号） |
| 播放进度（杀后台才存） | `Documents/playback_resume.json` | 只在杀后台时写，前台回前台不写、不 seek |

子目录文件本身不靠快照：覆盖安装后同一 bundle id 保留 Documents，Swift 侧
按相对名重扫目录重建索引（`LocalStore.LocalFileIndex`：加载先修后删、删前
重扫）。四个子目录：`music_downloads/`、`local_music/`、`wallpapers/`、
`fonts/`；另有 `music_playback_cache/`（边播边写缓存）与 `lx_scripts/`。

## 迁移（S1，本文档原“不迁移”结论作废）

> **作废说明（S0，2026-11-23）：** 本节原先写“2.0 是全新安装的地基，不做
> Hive → Swift 的自动迁移……2.0 首次启动即为空状态”。该结论与 chen 的硬
> 要求（用户数据零丢失）直接冲突，**作废**。迁移方案按 2.0 方案 §五执行，
> 三条路并行（S1 做）：
>
> - 路 A（主路）：Flutter 1.1.6.x 小版本先发，启动时把 `app_settings` 全量
>   导出为类型化 JSON 快照（`Documents/migration_snapshot.json`）；Swift
>   2.0 首次启动读快照、按本映射表写入、逐键计数校验，通过才标记
>   `migrationDone`。
> - 路 B（兜底）：现有备份 JSON（schema=1）导入，与 Flutter 侧逻辑一致
>   （先校验 envelope、快照当前、逐条写、失败全量回滚）。
> - 路 C（验证）：Hive 只读解析探针，证明快照没有漏键；探针不随 app 发布。
>
> 删前必有备份；不删 Hive box，直到迁移验证通过且用户已正常使用 2.0 一段
> 时间；删除只由用户在设置页手动触发。发布门：S6 备份导入 + 跨代迁移测
> 试通过之前，不许把 2.0.0 写进任何 `version.json`。

### 快照格式（路 A，S1 与 Flutter 侧快照 writer 的契约）

```json
{
  "schema": 1,
  "app": "HAo Studio",
  "appVersion": "1.1.6",
  "appBuild": 31,
  "exportedAt": "2026-11-23T00:00:00.000Z",
  "entries": 131,
  "data": { "<Flutter Hive 键>": <值> },
  "types": { "<Flutter Hive 键>": "string|int|double|bool|json|intList|doubleList" }
}
```

读侧容忍规则（`MigrationStore.validatedData` / `coerce`）：`schema` 必须
为 1；`appVersion` 存在时须为 `1.` 开头，缺失也接受；`types` 缺失时按 JSON
值本身推断类型；JSON 字符串值先解析再落盘，解析失败只跳过该键；`data`
为空或不是字典则整个快照视为无效，跳过迁移。备份 JSON（路 B）用同一信封，
`data` 同样是全量键值对，导入是 merge 不是 replace。

### 回滚与失败兜底（`MigrationStore` 实现）

1. 写前备份：快照文件 + 将被改动的 UserDefaults 值 + 将被覆盖的集合文件，
   复制到 `Documents/migration_backup/<yyyyMMdd-HHmmss>/`；备份建不出来则
   一步都不写，直接报失败。
2. 写中失败或逐键校验失败：全量回滚到迁移前状态（UserDefaults 恢复原值或
   删除新增键；集合文件恢复原内容或删除新建文件；Emby apiKey 恢复原值或
   从 Keychain 删除），`migrationDone` 保持 false，可重试。
3. 快照损坏/缺失/版本不符：跳过自动迁移，默认值启动，My 页提示“未找到旧版
   数据，可从备份文件导入”，不白屏不崩溃。
4. 坏类型备份导入：只跳过坏键，其余键照常落盘，不崩溃。
5. 绝不删除 Hive box 文件与快照文件；删除只在设置页由用户手动触发。
