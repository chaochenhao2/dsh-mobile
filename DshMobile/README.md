# DSH Mobile (iOS)

SwiftUI 客户端，连接 `dsh-mobile-bridge` 插件。

## 结构

```
DshMobile/
  project.yml                 # 工程唯一真源（XcodeGen）
  DshMobile/
    App/DshMobileApp.swift    # 入口、根路由
    Model/
      Models.swift            # 线协议类型
      BridgeAPI.swift         # HTTP + SSE 传输
      AppStore.swift          # 连接状态、会话列表
      ChatStore.swift         # 单个会话的转录与操作符折叠
      UDPDiscovery.swift      # 局域网广播发现
    View/
      ConnectView.swift       # 配对（自动发现 / 手动）
      SessionsView.swift      # 会话列表
      ChatView.swift          # 对话、流式输出、输入栏
      SettingsView.swift      # 连接信息与断开
      Theme.swift             # 配色与通用控件
    Assets.xcassets/          # AppIcon（1024 单尺寸）、AccentColor、LaunchBackground
```

`Support/Info.plist` 与 `DshMobile.xcodeproj` 由 `xcodegen generate` 生成，不入库。

## 关键点

- **纯 HTTP + SSE**，没有第三方依赖，也没有 WebSocket。
- **ATS 放开任意加载**：桥接是局域网明文 HTTP，靠 Bearer 令牌而不是 TLS 保护。
- **本地网络权限**：`NSLocalNetworkUsageDescription` 已声明；首次接收 UDP 广播或连接局域网地址时系统会弹窗。
- **流式渲染**：`URLSession.bytes(for:)` 按行读 `data:`，逐帧应用到节点列表；`reset` 重建、`delta` 追加、`update` 替换、`remove` 删除。
- **后台不保持连接**：离开会话页即取消订阅，Harness 侧照常运行。

## 配置

`project.yml`：

- `deploymentTarget.iOS: "16.0"`
- `PRODUCT_BUNDLE_IDENTIFIER: com.dshmobile.app`（重签时 Sideloadly 会改写）
- 想改包名/显示名/版本，改这里再让 CI 重新生成。

## 已知限制

- 审批、文件上传、图片 prompt、终端控制未实现（见根 README）。
- 长会话一次性拉取最近 400 条消息对齐的历史页；更早的内容需要后续分页。
- 转录按纯文本渲染，暂不解析 Markdown 与代码高亮。
