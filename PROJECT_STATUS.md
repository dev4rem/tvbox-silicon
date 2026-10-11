# PROJECT_STATUS.md — TCBox fork 交接文档

> 位置：`/Volumes/Jie_4T/apple/tvbox-silicon`（2026-10-11 由 `tmp/tvbox-silicon` 移至此，原主仓 checkout 已被替换）
> 更新：2026-10-11 · 基线 `7b66c6b`，全部改动未 commit

## 1. 当前目标

把 fork 做成可独立安装、日常可用的 **TVBox** 变体：修 macOS 27 播放崩溃，支持 M3U/TXT 直导，
与原应用并存（新名字 + 新 bundle ID + 独立数据目录），支持多个订阅并存、UI 内切换。

## 2. 已完成

- **播放崩溃修复**：`DesktopNativePlayer` / `PlayerSurface` 的 `controlsStyle` 改为 `.none`
  （floating/inline 的 SwiftUI scrubber 在 macOS 27 必现 `EXC_BREAKPOINT`，见 §5）；
  `present`/`windowWillClose` 先摘 `contentView` 再 `stop()`；`updateNSView` 只在 `!==` 时赋值。
- **M3U/TXT 直导**：`HTTPClient.subscription` 非 JSON 时回退解析 playlist，生成单 live 源；
  Settings 提示语更新；新增 `directPlaylistURLImportsAsSingleLiveSource` 测试。
- **重命名**：显示名 `TVBox`，bundle ID `com.tcbox.tvbox.{mac,ios,tv}`，TVCore 硬编码数据目录
  `com.tvbox.yingxia` → `com.tcbox.tvbox`，QA suite 同步；xcodegen 已重新生成。
- **多订阅并存**：`Store.entries: [SavedSubscription]` + `activeID`，每订阅独立数据文件，
  加新 URL 只追加（同地址刷新到位），Settings 列表管理（Refresh/Remove/Picker），
  Watch Now 有订阅切换 Menu；单文件旧数据自动迁移。
- **本地化**：新增 `Subscriptions` / `Add Subscription` / `Remove` / `TVBox, M3U or TXT URL`
  四语言条目；两仓 `check-localizations.py` 均通过。
- **可用构建**：`/Volumes/Jie_4T/Applications/TCBox.app`（Release ad-hoc，bundle `com.tcbox.tvbox.mac`）。
  Air 实测可导入 `http://192.168.0.24:8767/all.m3u`（ysp-live 源），-1009 问题消失。

## 3. 关键技术决策

- scrubber 问题是 Apple 回归（10+ 日志同签名，无应用帧），不修 bridge 代码，直接弃用原生时间轴。
- 数据目录必须随 bundle ID 分叉，否则两应用共享 `com.tvbox.yingxia/`（bundle ID 本身不隔离它）。
- 多订阅用“索引 + 独立文件”，`subscription` 计算属性保持为当前选中，各视图零改动。
- 用户选择：保留 Debug，不做 release 打包（见 §7）。

## 4. 核心文件（fork，相对根目录）

- `App/PlayerView.swift`、`App/Store.swift`（新增 `SavedSubscription`）、`App/SettingsView.swift`、`App/HomeView.swift`
- `Sources/TVCore/Network.swift`、TVCore 内 `com.tcbox.tvbox` 路径（9 文件）、4 份 `Localizable.strings`
- `project.yml`、`Tests/TVCoreTests/NetworkTests.swift`

## 5. 测试与验证

- fork：`swift test` 138 通过；`check-localizations.py` 519 keys 通过；
  `xcodebuild TVBox-macOS` 成功（输出被两仓共享的 `/Volumes/Jie_4T/Xcode/Product/Debug` 覆盖过一次，注意）。
- 主仓：`swift test` 未重跑；`check-localizations.py` 429 keys 通过；macOS 构建此前成功。

## 6. 已知问题

- 去原生时间轴后只有键盘/顶栏可 seek，无拖拽进度条、无 PiP 按钮。
- 应用内仍有多处 “Yingxia” 文案，更新 feed 仍指向原项目（会有原版更新提示）。
- fork 基线旧于主仓（`7b66c6b` vs `bb5352a`），直接合入主仓新功能会冲突。
- Air 导入 -1009 的排查结论：服务端（ysp-live `:8767`）与 LAN 路径正常，Air 上 curl 200、
  同一二进制在 mini 正常；换 Release ad-hoc 构建后 Air 导入正常。
  Debug 构建为何只在 Air 报 -1009 未定位（待确认：构建差异还是当时 Air 侧网络状态），
  不要写成定论。

## 7. 试过但失败的方案

- `controlsStyle = .inline`：仍走同一 SwiftUI scrubber，Debug 构建（dylib `61be2fdc`）继续同签名崩溃。
- 仅调整 `replaceCurrentItem` 时序：崩溃发生在 SwiftUI 事务 flush，与 teardown 时序无关。
- `/tmp/DerivedData-*` 做构建输出：系统清 `/tmp`；本工程实际输出到 `/Volumes/Jie_4T/Xcode/Product/Debug`。

## 8. 原主仓状态（已失效）

- 原 `/Volumes/Jie_4T/apple/tvbox-silicon` 主仓（`bb5352a` + 未 commit 改动）在本次移库时被替换，无备份。
- 其中独特的中间态 PlayerView 修复已被 fork 超集覆盖；M3U 回退与 key 回填在 fork 均有。
- 如需找回主仓新功能（downloads queue 等），从上游重新 clone。

## 9. 下一步顺序

1. 真机冒烟：`TCBox.app` 播 VOD + 直播 + 切订阅，确认无崩溃。
2. 自绘进度条（补 `.none` 丢掉的 scrub）：建议放顶栏下，复用 `session.skip`。
3. 文案/feed 二选一：全量改 “TVBox” 或禁用更新检查。
4. commit fork 改动（`build/` 已 ignore；`project.pbxproj` 含本机路径， review 后再提）。
5. 要分发才做 release：改 `package-mac-release.sh` 的 Yingxia 硬编码 + Developer ID。
