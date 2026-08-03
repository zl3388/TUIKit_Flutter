# Android 构建与发布

## 已验证环境

| 组件 | 版本或路径 |
| --- | --- |
| Flutter | 3.44.8 stable，`D:\Programs\flutter` |
| Dart | 3.12.2 |
| Android Studio | 2026.1.2 |
| Android SDK | `D:\Programs\Android\SDK` |
| compileSdk / targetSdk | 36 / 36 |
| minSdk | 24，Android 7.0 |
| Build Tools | 36.0.0 |
| NDK | 30.0.15729638 rc2 |
| JDK | Android Studio JBR 21.0.10 |
| Gradle | 9.1.0 |
| Android Gradle Plugin | 9.0.1 |
| Kotlin Gradle Plugin | 2.3.20 |

`flutter doctor -v` 已通过，Android 许可证与网络资源均正常。

## 本机构建配置

`application/android/local.properties` 被 Git 忽略，当前绑定：

```properties
sdk.dir=D:\\Programs\\Android\\SDK
flutter.sdk=D:\\Programs\\flutter
```

构建使用环境变量：

```powershell
$env:ANDROID_HOME='D:\Programs\Android\SDK'
$env:ANDROID_SDK_ROOT='D:\Programs\Android\SDK'
$env:JAVA_HOME='D:\Programs\Android\Android Studio\jbr'
```

## 可选本地网络配置

仓库不设置 HTTP、Git 或 Flutter/Pub 代理。需要代理的开发机可使用被 Git 忽略的 `.local/network.ps1`；没有该文件时构建命令不会主动修改网络环境。

本地配置格式：

```powershell
$proxy='http://<proxy-host>:<proxy-port>'
$env:HTTP_PROXY=$proxy
$env:HTTPS_PROXY=$proxy
$env:ALL_PROXY=$proxy
$env:GIT_HTTP_PROXY=$proxy
$env:GIT_HTTPS_PROXY=$proxy
```

不要使用 `git config --global` 或提交真实代理地址。代理只在显式加载该本地文件的 PowerShell 进程及其子进程中生效。

## 构建命令

```powershell
cd application
if (Test-Path ..\.local\network.ps1) { . ..\.local\network.ps1 }
flutter --no-version-check pub get
flutter --no-version-check build apk --release --no-pub --build-name 0.2.0 --build-number 3
```

首个基线产物：

```text
dist/android/TUIKit-OfflineDemo-baseline-0.1.0+1.apk
```

| 属性 | 值 |
| --- | --- |
| 大小 | 247.76 MB |
| SHA-256 | `8090FC191F7753DCD2EB7D833163D18BC6D5D5EFE31BF4920A6CD316D0387D31` |
| 包名 | `com.trtc.uikit.livekit.example` |
| 版本 | `0.1.0` (`versionCode 1`) |
| ABI | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| 签名 | APK Signature Scheme v2，Android Debug 证书 |

## 真机启动修复产物

```text
dist/android/TUIKit-OfflineDemo-baseline-hotfix-0.1.1+2.apk
```

| 属性 | 值 |
| --- | --- |
| 大小 | 247.79 MB |
| SHA-256 | `03CA14A4559130E3F3C3C9D4A541894E350E0018BA32D8A41B4635AC4BAFD463` |
| 包名 | `com.trtc.uikit.livekit.example` |
| 版本 | `0.1.1` (`versionCode 2`) |
| ABI | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| 签名 | APK Signature Scheme v2，Android Debug 证书 |
| 验证范围 | 构建、AAPT、签名、Room 反射构造函数、Redmi K80 Pro 冷启动和登录页冒烟 |

旧 `0.1.0+1` 包在 Redmi K80 Pro 冷启动时崩溃。WorkManager 2.8.1 依赖 Room 2.5.0，AGP 9/R8 裁剪了反射调用的 `WorkDatabase_Impl()` 无参构造函数。应用级 ProGuard 规则现保留所有 Room 数据库实现的无参构造函数。

## P1 纯离线产物

```text
dist/android/TUIKit-OfflineDemo-P1-0.2.0+3.apk
```

| 属性 | 值 |
| --- | --- |
| 文件大小 | 98,438,591 字节（约 93.9 MB） |
| SHA-256 | `C513654A6DC3CF512154E47E02BDF66EBC40C20ABEA91B6D9FD72606EED01139` |
| 包名 | `com.trtc.uikit.livekit.example` |
| 版本 | `0.2.0` (`versionCode 3`) |
| SDK | min 24 / target 36 / compile 36 |
| ABI | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| 签名 | APK Signature Scheme v2，Android Debug 证书 |
| 权限 | 仅应用动态广播接收器签名权限；无 `INTERNET`、相机、麦克风和存储权限 |
| 原生依赖 | 不含 LiteAV、TRTC、IM SDK 和 TUIKit 原生库 |

`file_picker` 固定为 `10.3.10`。其 11.x 版本在当前 AGP 9/Built-in Kotlin 组合下会禁用 Kotlin 插件并导致构建失败。

## P2 消息候选产物

```text
dist/android/TUIKit-OfflineDemo-P2-messaging-0.3.0+4.apk
```

| 属性 | 值 |
| --- | --- |
| 文件大小 | 101,027,739 字节 |
| SHA-256 | `6B587BCE5C0B74B5CFFD809A0C88296BB02D196EC66EEA32852AC472AE6615C3` |
| 版本 | `0.3.0` (`versionCode 4`) |
| SDK / ABI | min 24 / target 36；`arm64-v8a`, `armeabi-v7a`, `x86_64` |
| 签名 | APK Signature Scheme v2，Android Debug 证书 |
| 权限 | 无 `INTERNET`、相机、麦克风和存储权限 |
| 当前验证 | 构建、静态检查、8 项测试、覆盖安装、搜索框与聊天输入器渲染 |
| 待验证 | 真机点击发送、会话摘要更新、强制停止后的消息持久化 |

## P2 会话管理候选产物

```text
dist/android/TUIKit-OfflineDemo-P2-conversations-0.4.0+5.apk
```

| 属性 | 值 |
| --- | --- |
| 文件大小 | 101,617,851 字节 |
| SHA-256 | `1BDB5EC997629B599637FD446DCA099A72FA1873528D1D0BF3E1AC8667785480` |
| 版本 | `0.4.0` (`versionCode 5`) |
| SDK / ABI | min 24 / target 36；`arm64-v8a`, `armeabi-v7a`, `x86_64` |
| 签名 | APK Signature Scheme v2，Android Debug 证书 |
| 权限 | 仅应用动态广播接收器签名权限；无 `INTERNET`、相机、麦克风和存储权限 |
| 当前验证 | 离线模块静态分析、完整 10 项测试、v1→v2 迁移、Release 构建、AAPT 和签名检查；360 1707-A01 完整 P2 真机流程 |
| 后续矩阵 | Redmi K80 Pro 高版本回归与飞行模式完整流程留待 P4 |

## P2 真机验证

| 项目 | 结果 |
| --- | --- |
| 设备 | 360 `1707-A01` (`192.168.2.50:5555`)，Android 7.1.1 / API 25 |
| 安装版本 | `0.4.0` (`versionCode 5`)，`adb install -r` 返回 `Success` |
| 冷启动 | `Status: ok`、`TotalTime: 723 ms`，进程存活且 `MainActivity` 在前台 |
| 搜索 | 屏幕键盘输入 `16` 后，4 个会话过滤为唯一的“全员公告” |
| 会话状态 | 产品项目组标为已读、置顶并开启免打扰；强制停止后仍位于首位，菜单保持“取消置顶/开启提醒” |
| 草稿 | 输入 `draft` 后列表显示 `[草稿] draft`；强制停止后列表和输入框均恢复草稿 |
| 文本发送 | 发送后输入框清空、消息气泡和会话摘要更新；再次强制停止后消息仍存在且草稿为空 |
| 删除 | 确认框明确提示级联删除本地消息和附件；删除离线助手后会话数 4 -> 3，强制停止后仍为 3 |
| 日志 | 全流程无 AndroidRuntime `FATAL EXCEPTION` |

## P1 真机验证

| 项目 | 结果 |
| --- | --- |
| 设备 | Redmi K80 Pro (`24122RKC7C`)，Android 16 |
| 安装版本 | `0.2.0` (`versionCode 3`) |
| 安装 | `adb install -r` 返回 `Success` |
| 冷启动 | 强制停止后成功，`LaunchState: COLD`、`Status: ok`、`TotalTime: 199 ms` |
| 进程 | 启动后存活，`MainActivity` 位于前台 |
| 页面 | 消息、通讯录、工作台、我的均由 UI Automator 验证内容和边界 |
| 持久化 | 通知未读数 2 -> 1；强制停止并重启后仍为 1 |
| 日志 | 无 `FATAL EXCEPTION`、WorkDatabase、SDKAppID、TRTC、LiteAV、IM SDK 或腾讯云登录记录 |

基线热修复包 `0.1.1+2` 的冷启动 440 ms 仍保留作为 P0 记录；后续功能验证应使用 P1 `0.2.0+3`。

## 已解决的最新版兼容问题

1. AGP 9 不再接受 `proguard-android.txt`，已改用 `proguard-android-optimize.txt`。
2. Flutter 3.44 删除 `ExtendSelectionByPageIntent`，聊天组件已移除旧映射并使用现有的相邻页面选区实现。
3. C 盘 Pub Cache 与 D 盘工程导致 Kotlin 增量缓存跨盘崩溃，工程已设置 `kotlin.incremental=false`。
4. 腾讯插件的 Java 目标分别为 1.8、11、17，根 Gradle 脚本按模块同步 Kotlin JVM target。
5. 部分 Compose/AndroidX AAR 要求 API 35 以上，所有 Android library 子模块通过 `finalizeDsl` 统一到 compileSdk 36。
6. 构建过程自动补装 Android Platform 31 与 CMake 3.22.1。
7. Room 2.5.0 的生成数据库由反射创建，已增加无参构造函数 keep 规则，避免 AGP 9/R8 在 release 包中裁剪。

## 当前警告与后续项

- 应用模块与 `file_picker 10.3.10` 仍显式应用 Kotlin Gradle Plugin；Flutter 当前只警告，但未来版本会要求迁移到 Built-in Kotlin。
- 部分第三方模块仍以 Java 8 编译，JDK 21 会输出弃用警告。
- SDK Command-line Tools 仍提示只能理解 XML schema 3，而新 SDK 元数据使用 schema 4；当前不阻断构建，后续升级命令行工具。
- 当前 Release 使用 Debug 证书。正式测试渠道需要独立测试 keystore，并安全保存密码。
- 当前包名、应用名、图标和腾讯品牌资源尚未替换。
- P1 已将 APK 从约 247.8 MB 降至 93.9 MB；历史整目录 assets、三 ABI、原图标和品牌资源仍需在 P6 继续清理。

## 每次 APK 验证

```powershell
$apk='dist\android\<file>.apk'
Get-FileHash $apk -Algorithm SHA256
D:\Programs\Android\SDK\build-tools\36.0.0\aapt2.exe dump badging $apk
D:\Programs\Android\SDK\build-tools\36.0.0\apksigner.bat verify --verbose --print-certs $apk
D:\Programs\Android\SDK\platform-tools\adb.exe install -r $apk
```

静态验证不能替代真机测试；每个候选 APK 仍需执行安装、强制停止后的冷启动、关键页面冒烟与持久化回归。
