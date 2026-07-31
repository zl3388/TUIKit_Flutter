# 事实进度

最后更新：2026-07-31

## 里程碑进度

进度百分比按路线图权重计算，只统计已满足验收条件的工作。

| 里程碑 | 权重 | 完成度 | 状态 | 验证依据 |
| --- | ---: | ---: | --- | --- |
| P0 最新版构建基线 | 15% | 100% | 已完成 | 修复包在 Redmi K80 Pro 冷启动及登录页冒烟通过 |
| P1 离线应用骨架 | 20% | 100% | 已完成 | SQLite schema、仓储、种子、媒体、测试及无云启动均已验证 |
| P2 核心用户体验 | 25% | 22% | 进行中 | 主导航、我的、通知中心和企业公告已在真机验证 |
| P3 管理模式编辑器 | 20% | 0% | 未开始 | 尚无模式切换、编辑器、快照和审计记录 |
| P4 模拟与离线验收 | 10% | 0% | 未开始 | 尚未完成飞行模式完整流程和持续网络监测 |
| P5 工作台扩展 | 5% | 0% | 待规划 | 邮件、文档、会议、工作台为后续范围 |
| P6 测试发布完善 | 5% | 0% | 未开始 | 独立包名、品牌和测试签名尚未完成 |
| **总计** | **100%** | **41%** | **进行中** | P0/P1 已完成，P2 已完成 2/9 个任务 |

## 2026-07-27

### 已验证

- 安装并识别 Flutter 3.44.8、Dart 3.12.2、Android Studio 2026.1.2、API 36、NDK 30、JDK 21。
- `flutter doctor -v` 无问题，Android 许可证全部接受。
- `application` 解析 129 个依赖成功。
- 静态分析无编译错误，有 55 条既有 warning/info。
- 完成 AGP 9、Gradle 9.1、Kotlin 2.3.20 和 API 36 迁移。
- 修复 Flutter 3.44 vendored text field API 不兼容。
- 修复 Kotlin 跨盘增量缓存、模块 JVM target 与 compileSdk 不一致。
- Release APK 构建成功并复制到 `dist/android`。
- APK 确认 minSdk 24、targetSdk 36、三种 ABI、v2 签名有效。

### 未验证

- 没有连接 Android 真机，因此尚未执行安装、启动和页面冒烟测试。
- 当前 SDKAppID 为 0 且登录依赖云服务，基线 APK 无法作为离线体验包使用。
- Debug 证书仅证明 APK 可签名，不代表测试发布签名已完成。


## 2026-07-30

### 已验证

- Redmi K80 Pro 成功安装 `0.1.0+1` 基线包，但点击图标立即闪退。
- Logcat 定位为 AndroidX Startup 初始化 WorkManager 2.8.1 时，Room 2.5.0 无法反射实例化 `WorkDatabase_Impl`。
- R8 `usage.txt` 证实旧包裁剪了 `WorkDatabase_Impl()` 无参构造函数。
- 已添加 Room 数据库构造函数 keep 规则，并构建 `0.1.1+2` 修复包。
- APK Analyzer 确认修复包包含 `public WorkDatabase_Impl()`；AAPT 元数据和 APK v2 签名校验通过。

### 进行中

- ADB 已识别 Redmi K80 Pro；覆盖安装被手机端以 `INSTALL_FAILED_USER_RESTRICTED` 取消，等待允许调试安装后复测。
- 修复包尚未完成冷启动和基础页面冒烟，P0 保持进行中。

### 风险变化

- AGP 9/R8 与工程中的旧 Room 2.5.0 存在反射构造函数裁剪风险，当前由应用级 keep 规则兼容。
- `0.1.0+1` 基线包不得继续用于启动测试。


## 2026-07-31

### 已验证

- Redmi K80 Pro 已安装 `0.1.1+2`，系统报告 `versionCode=2`、`versionName=0.1.1`。
- ADB 强制停止后冷启动成功：`LaunchState: COLD`、`Status: ok`、`TotalTime: 440 ms`。
- 启动 5 秒后应用进程仍存活，`MainActivity` 保持 `topResumedActivity`。
- Logcat 不再出现 WorkManager/Room `FATAL EXCEPTION`。
- UI Automator 确认登录页标题、用户 ID 输入框、登录按钮和测试环境开关均已渲染且可交互。
- 在线登录因 `SDKAppID=0` 返回错误 6017，属于当前基线包的已知业务限制，不影响 P0 构建与启动验收。

### 阶段结论

- P0 最新版构建基线验收完成。
- 下一阶段进入 P1：建立本地持久化、离线身份和不初始化腾讯云 SDK 的离线入口。

### P1 离线骨架验证

- `application/lib/main.dart` 已切换到 `OfflineDemoApp`，启动路径不再引用或初始化腾讯 IM、TRTC、直播、会议和通话 SDK。
- 建立 schema v1，共 11 张 SQLite 表；身份、组织、联系人、会话、消息、附件、通知、公告、通话记录和设置均通过仓储访问。
- 确定性种子场景包含 1 个当前身份、4 个联系人、4 个会话、消息、2 条通知、2 条公告和 2 条通话记录。
- 本地媒体支持导入复制、相对路径校验、320px 图片缩略图和孤儿文件清理。
- `flutter test` 共 6 项通过；离线源码 `dart analyze` 无问题。
- 已从离线应用依赖图移除 `tencent_*_uikit` 和 `atomic_x_core`；最终 APK 不含 LiteAV/TRTC/IM/TUIKit 原生库。
- AAPT 权限检查确认最终 APK 不声明 `INTERNET`、相机、麦克风或存储权限。
- Redmi K80 Pro 已完成安装、四个主页面冒烟和强制停止后的冷启动；`TotalTime: 199 ms`，无 `FATAL EXCEPTION`。
- 通知已读数从 2 更新为 1，强制停止并重启后仍为 1，验证 SQLite 持久化。
- 最终产物：`dist/android/TUIKit-OfflineDemo-P1-0.2.0+3.apk`，98,438,591 字节，SHA-256 `C513654A6DC3CF512154E47E02BDF66EBC40C20ABEA91B6D9FD72606EED01139`。
- Git `origin` 已切换为 `https://github.com/zl3388/TUIKit_Flutter.git`，并验证 fork 的 `main` 分支可访问。

### 风险变化

- 在线 UIKit 源码仍保留作参考，但已不在 `application` 的离线依赖图中；若未来恢复在线 flavor，必须使用独立依赖配置。
- 历史腾讯图像资源仍因整目录 assets 声明进入 APK，且包名、应用名、图标与 Debug 签名尚未替换，留待 P6。
- `file_picker` 固定为 `10.3.10` 以兼容 AGP 9；Flutter 仍提示未来迁移 Built-in Kotlin。
- 尚未执行系统飞行模式完整流程，P4 离线验收保持未完成。
## 更新模板

```markdown
## YYYY-MM-DD

### 已验证
- 事实、命令或测试结果

### 进行中
- 当前工作与阻断点

### 风险变化
- 新增、关闭或调整的风险
```