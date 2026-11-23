# HAo Studio 独立版 2.0

Swift 原生重写的独立 IPA：零网站连接，不登录、无商店、无社区、无后台，
所有流量走手机直连。2.0 不再是旧的网页壳——界面、主题、播放器全部原生。

> 状态：2.0.0 已发布（2026-11-23）。Swift 原生重写完成：首页聚合
> （继续观看/继续听/热门直播/每日推荐/最近播放）、音乐（LX 解析、
> AVPlayer、歌词在封面后、5 档音质、自动续播断点）、影视（Infuse 风格
> 详情页、Emby、继续观看）、直播（Bilibili/斗鱼/虎牙/抖音/快手 5 平台、
> 弹幕只收不发、画质/线路切换）、我的/设置（7 组设置、源管理、Emby 配置、
> 备份导出/导入、在线更新）。4 主题 × 浅/深，底栏玻璃，启动动画 #4。

## 工程

- `ios/HAoStudio.xcodeproj` — 单 target `HAoStudio`（bundle id
  `com.haostudio.standalone`，iOS 17.0，Swift 5.0）。旧的 Lyrics 扩展、
  Podfile、web 前端、外部元数据服务配置已全部删除。
- `ios/HAoStudio/` — SwiftUI 源码：
  `HAoStudioApp.swift`（@main 入口）、`Theme/`（4 主题 × 浅/深）、
  `App/`（5-tab 导航、玻璃底栏、迷你播放器）、`Playback/`（播放协调器壳）、
  `Storage/`（UserDefaults 设置 + Documents JSON 集合）、`Splash/`（启动动画 #4）。
- `codemagic.yaml` — 工作流 `ios-unsigned`（push 到 `main`
  即构建），产物 `ios/HAoStudio.ipa`。libmpv 由构建时下载（不在仓库里）。
- `version.json` — 2.0.0 / build 33 / minOs 17.0，ipaUrl 指商店的
  `HAoStudio-standalone-v2.0.0.ipa`。size 在构建出包后补真实值。
- `docs/` — `splash-animation-4-spec.md`（启动动画规格）、
  `storage-mapping.md`（Flutter Hive 键 → Swift 存储映射）。

## 铁律（摘要，完整版见任务书）

- 4 主题 × 浅/深 = 8 种组合都要过；不写死颜色；不许紫色；红色只用于
  LIVE 徽标/录制点；蓝色元素改黑。
- 点播与直播两套逻辑绝不混用；音质选择器只在直播；长按 2 倍速只在点播。
- 解析按速度串行问源，第一个能播立刻播，不许问完全部。
- 无登录界面：需平台登录的功能不许加。
- 音乐只用 AVPlayer；歌词在封面背后。
- 本地文件索引只存相对名，加载先修后删，删前重扫目录。

## 构建

Codemagic，workflow `ios-unsigned`（branch main），产物 `ios/HAoStudio.ipa`。

- push 到 `main` 即触发构建。编译验证走 Codemagic（Swift app id
  `6afa12e482fb30c0f828e6e3`，仓库 haostudio-standalone-2.0）。
- 本机预检：`python3 ios/preflight_check.py`（检查工程引用、资产、
  Info.plist、启动动画数值、主题色值、版本对齐、codemagic 配置；不代替编译）。

## 在线更新

App 先读商店的 `https://chen-hao-shop-production.up.railway.app/version.json`
检查更新，失败时读 Gitee 兜底
`https://gitee.com/chenhao030610/chen-hao-shop/raw/master/version.json`，
提示后由用户在 Safari 下载 IPA、经 LCSign / TrollStore 安装
（侧载应用无法静默安装）。
