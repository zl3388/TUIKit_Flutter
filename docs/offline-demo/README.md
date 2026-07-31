# 离线演示版总览

## 目标

将 `application` 改造成无需业务服务器和腾讯云账号即可运行的 Android 离线测试应用，用于 UI 演示、交互演示、用户端能力测试和场景模拟。管理模式可以编辑所有本地演示数据，切回用户模式后立即呈现并跨重启保留。

## 当前事实

- P0 最新工具链与 P1 离线骨架均已完成，当前总进度为 41%。
- `application/lib/main.dart` 直接启动 `OfflineDemoApp`，无需账号、SDKAppID 或业务服务器。
- SQLite schema v1、仓储、确定性种子、本地媒体与四栏主导航已落地；P2 已完成主导航/我的和通知/公告两个任务。
- 离线应用依赖图已移除腾讯 IM、TRTC、直播、会议、通话 UIKit 及 `atomic_x_core`；APK 不声明 `INTERNET` 权限。
- `dist/android/TUIKit-OfflineDemo-P1-0.2.0+3.apk` 已在 Redmi K80 Pro 完成冷启动、页面冒烟和重启持久化验证。
- 当前 APK 为 98,438,591 字节，SHA-256 为 `C513654A6DC3CF512154E47E02BDF66EBC40C20ABEA91B6D9FD72606EED01139`。
- 包名 `com.trtc.uikit.livekit.example`、应用名 `app-uikit`、历史品牌资源和 Android Debug 证书尚未替换，留待 P6。
- Git `origin` 已切换至 `https://github.com/zl3388/TUIKit_Flutter.git`。
## 文档索引

- [Android 构建与发布](BUILD_ANDROID.md)
- [离线架构](ARCHITECTURE.md)
- [管理模式 UX](UX_ADMIN_MODE.md)
- [开发路线图](ROADMAP.md)
- [TODO](TODO.md)
- [事实进度](PROGRESS.md)

## 维护规则

1. `PROGRESS.md` 只记录已经验证的事实，不把计划写成完成状态。
2. `TODO.md` 是唯一任务状态清单；任务状态变化时必须同步更新时间和验证依据。
3. 架构或交互决策变更时，同一提交中更新对应文档。
4. 每个 APK 必须记录版本、路径、SHA-256、签名类型、最低/目标 Android 版本和验证范围。
5. “离线可用”必须通过飞行模式、无账号、冷启动、编辑后重启持久化四项验证，不能仅以编译成功认定。