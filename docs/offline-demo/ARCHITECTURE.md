# 离线架构

## 原在线工程判断

现有 `application` 不是可替换一个网络客户端就能离线化的薄壳：

- 登录页直接调用 `LoginStore`、`TUICallKit`、`TencentImSDKPlugin` 和 `TUIRoomEngine`。
- 会话、联系人和消息组件直接创建 `ConversationListStore`、`MessageListStore` 等 `atomic_x_core` 托管类型。
- 通话、会议和直播组件内部包含原生 SDK、事件总线、房间状态和网络服务。
- `atomic_x_core` 是 Pub 依赖，不在本仓库中，直接伪造全部 SDK 行为会形成高维护成本的脆弱适配层。

因此采用“离线领域层 + 本地仓储 + 场景模拟器 + 独立展示壳”，不在原生腾讯 SDK 边界上做全局假服务。现有 UIKit 保留作视觉和交互参考，可选择性复用无 Store 依赖的纯展示组件。

## P1 实际结构

```text
application/lib/src/offline_demo/
  bootstrap/offline_bootstrap.dart  # 数据库、媒体与仓储装配
  data/
    offline_database.dart           # 连接、事务和仓储实现
    offline_schema.dart             # schema v1 与迁移入口
    offline_seed.dart               # 确定性最小场景
    local_media_store.dart          # 导入、缩略图和清理
  domain/
    models.dart                     # 领域模型
    repositories.dart               # 仓储接口
  state/offline_demo_store.dart     # 页面状态与持久化操作
  presentation/                     # 导航、主题和用户端页面
  offline_demo_app.dart             # 离线应用入口
```

`OfflineDemoBootstrap` 初始化 SQLite 和本地媒体目录后直接装载默认身份，不调用云登录。在线 UIKit 源码继续保留作参考，但 `application/pubspec.yaml` 不再依赖腾讯 UIKit 或 `atomic_x_core`，因此原生插件不会自动注册。P2/P3 将在现有领域和仓储边界上增加消息写入、模拟器与管理页面。
## 数据存储

使用 SQLite 保存结构化数据，应用支持目录保存图片、音视频、文档和缩略图。数据库只保存相对路径、MIME、大小、校验和与展示元数据，不把大文件写入 BLOB。

### Schema v1 已落地表

| 表 | 作用 |
| --- | --- |
| `profiles` | 当前离线身份、头像、状态、职位和资料 |
| `org_units` | 企业/部门及层级关系 |
| `contacts` | 联系人资料、部门、职位、状态和标签 |
| `conversations` | 单聊、群聊、系统会话及置顶/免打扰/未读状态 |
| `conversation_members` | 会话成员关系 |
| `messages` | 消息方向、类型、正文、发送状态和时间 |
| `message_attachments` | 本地附件、缩略图、MIME 和大小 |
| `notifications` | 通知内容、分类和已读状态 |
| `announcements` | 企业公告、发布者、发布时间和已读状态 |
| `call_records` | 本地通话类型、方向、结果、时长和参与者 |
| `settings` | 当前身份、模式、主题和场景设置 |

P1 数据库版本为 1，启用外键和索引。首次启动在事务中写入确定性种子；已有数据库不会重复插入。测试覆盖首次初始化、重开保留修改、事务回滚和相对路径安全。

### 后续表规划

P2/P3/P5 按功能增加 `contact_memberships`、`workbench_apps`、`meetings`、邮件、文档、`scenario_rules`、`audit_events` 和 `snapshots`。核心字段继续使用明确列和约束，只有未来扩展属性进入 `extra_json`，避免把整个数据模型退化为不可迁移的 JSON。
## 领域类型

消息采用带类型的统一模型，第一批支持：

- 文本、富文本片段、引用和回复。
- 图片、视频、语音、文件和本地链接。
- 语音/视频通话记录。
- 系统提示、撤回、入群、公告和时间分隔。
- 发送中、已发送、已送达、已读和失败状态。

后续扩展位置、名片、投票、审批、会议邀请、邮件摘要和文档分享，不修改会话主结构。

## 仓储边界

页面通过 `OfflineDemoStore` 调用仓储，不直接访问 SQLite。P1 接口保持小而明确，例如：

```dart
abstract interface class ConversationRepository {
  Future<List<OfflineConversation>> listConversations();
  Future<List<OfflineMessage>> listMessages(String conversationId);
  Future<List<OfflineAttachment>> listAttachments(String messageId);
}
```

`OfflineRepositoryBundle` 装配身份、联系人、会话、活动和设置仓储。通知已读写入由 `ActivityRepository` 完成；文本发送由 `ConversationRepository.sendTextMessage` 在一个事务中写入消息并同步会话最后消息与排序时间。后续未读、撤回和删除同样必须通过仓储事务维护派生字段。

## 场景与模拟器

场景包由 `manifest.json`、结构化数据和媒体目录组成，可内置、导入、导出和复制。运行时模拟器只处理本地事件：

1. 发送消息后写入 `sending`，按规则延迟变为 `sent`、`delivered` 或 `read`。
2. 自动回复规则可按联系人、关键字、时间和概率触发。
3. 来电、会议邀请和系统通知使用本地时间线调度，不访问推送服务。
4. 通话与会议页面使用本地状态机推进“呼叫中、已接通、结束”等 UI，不建立媒体房间。
5. 重置场景从快照恢复，导入前验证 schema 版本和媒体校验和。

测试应注入可控时钟和确定性随机源，保证自动化结果可重复。

## 模式与持久化

`AppModeController` 是全局状态的唯一来源，值为 `user` 或 `admin`。模式本身和管理会话过期时间保存在本地设置中；业务数据不随模式切换复制，两个模式观察同一数据库，因此切换后立即看到编辑结果。

管理写操作统一经过 command/service 层并记录 `audit_events`。删除、批量替换和场景重置必须先生成快照，支持单步撤销和整包恢复。

## 网络隔离策略

P1 已将隔离落实到构建依赖和 Android 权限，而不只是运行时避开登录：

- `main.dart` 的入口依赖树不包含腾讯 UIKit、`atomic_x_core` 或云登录。
- `application/pubspec.yaml` 已移除腾讯 IM、TRTC、直播、会议和通话包，生成的插件注册表不再注册这些插件。
- 最终 APK 不包含 LiteAV/TRTC/IM/TUIKit 原生库，也不声明 `android.permission.INTERNET`。
- 默认身份、联系人、会话、通知和公告全部由 SQLite 与本地种子提供；媒体只保存应用支持目录中的相对路径。
- Redmi K80 Pro 的冷启动日志没有腾讯域名、SDKAppID、IM、TRTC 或网络登录记录。

P4 仍需补充系统飞行模式下的完整交互、长时间网络调用监测和大数据集测试。无 `INTERNET` 权限已经形成强约束，但不能替代这些端到端验收。

## 数据迁移与备份

数据库从版本 1 开始，每次 schema 变更必须提供正向迁移和迁移测试。场景导出包含 schema 版本、应用版本和 SHA-256；导入先在临时数据库验证，成功后事务替换，失败不影响现有数据。