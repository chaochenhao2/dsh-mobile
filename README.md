# DSH Mobile

在手机上读取并驱动电脑里的 **DeepSeek Harness**。

两个产物，一个协议：

| 目录 | 内容 |
| --- | --- |
| `dsh-mobile-bridge/` | DSH Host 插件。随 Harness 启动，在局域网端口上提供 HTTP + SSE 接口，并把 DSH 会话事件折叠成手机能直接渲染的转录。 |
| `DshMobile/` | SwiftUI iOS App。发现电脑、浏览会话、实时跟随转录、发 prompt、取消回合。 |
| `.github/workflows/ios.yml` | 在 macOS runner 上用 Xcode 编译**未签名 IPA**（可直接用 Sideloadly / AltStore 重签安装）。 |
| `tools/` | 开发期自检脚本（桥接冒烟测试、Swift 结构检查）。 |
| `_upstream/` | 只读参考：`deepseek-ai/deepseek-harness` 在 `dsh-v0.2.2-rc.3` 的源码，已被 `.gitignore` 排除。 |

## 1. 装插件

插件已经安装进当前 profile（`desktop`），并在每次 Harness 启动时自动运行。

- 首次激活时插件自己生成配对令牌并写入 `~/.dsh/mobile-bridge/config.json`。
- 端口默认 `5180`；局域网广播默认开启（UDP `5181`）。

令牌形如：

```json
{
  "host": "0.0.0.0",
  "port": 5180,
  "discovery": true,
  "discoveryPort": 5181,
  "includeTokenInBeacon": false,
  "token": "0123456789abcdef0123456789abcdef"
}
```

自检（不需要手机）：

```powershell
$env:DSH_HOME = "$env:USERPROFILE\.dsh"
node tools/bridge-smoke.mjs
```

它会走完整链路：读 info → 建会话 → 订阅 SSE → 发 prompt → 打印转录 → 必要时取消。

## 2. 编译 IPA

仓库推到 GitHub 后，**Actions → Build unsigned IPA → Run workflow**（或直接 push 到 `main`）。

流水线两步：

1. `parse` — 用 `swiftc -parse` 对全部 Swift 文件做纯语法检查，几十秒出结果。
2. `build` — `brew install xcodegen` → `xcodegen generate` → `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO` → 打包成 `Payload/DshMobile.app` 的 zip，产出 `DshMobile-<version>-unsigned.ipa`。

下载 artifact 后：

- **Sideloadly / AltStore / SideStore**：拖入 IPA，用你自己的 Apple ID 重签安装（免费账号 7 天有效，开发者账号 1 年）。
- 真机首次打开会请求**本地网络**权限；必须允许，否则连不上电脑。

本地（macOS）等价命令：

```bash
cd DshMobile
brew install xcodegen
xcodegen generate
xcodebuild -project DshMobile.xcodeproj -scheme DshMobile \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

> `DshMobile.xcodeproj` 与 `Support/Info.plist` 都由 XcodeGen 从 `project.yml` 生成，**不入库**；改工程配置请改 `project.yml`。

首次构建失败时怎么读日志、怎么定位报错行：见 [DshMobile/docs/RELEASE.md](DshMobile/docs/RELEASE.md)。

## 3. 连接

App 打开后两种方式：

- **自动发现**：同一 Wi-Fi 下点「自动发现」，插件每 3 秒广播一次，列表里会直接出现电脑名与版本。
- **手动填写**：主机 = 电脑的局域网 IP（如 `192.168.1.160`），端口 `5180`，令牌 = 上面 `config.json` 里的值。

默认令牌**不在广播里**，所以自动发现之后仍需粘贴一次令牌。若你信任所在网络，可在 `config.json` 把 `includeTokenInBeacon` 改成 `true`，实现零输入配对；代价是同网段任何设备都能直接控制这台电脑。

## 协议

除探活外，所有请求都要 `Authorization: Bearer <token>`。

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| `GET` | `/api/health` | 探活，无需令牌。 |
| `GET` | `/api/info` | Harness 版本、profile、主机名、网卡、Web GUI 地址、能力清单。 |
| `GET` | `/api/sessions` | 会话列表（标题、目录、运行状态，按更新时间倒序）。 |
| `POST` | `/api/sessions` | 新建会话。 |
| `GET` | `/api/session/:id` | 转录 + 状态 + 标题。 |
| `GET` | `/api/session/:id/stream` | SSE：`reset` / `op` / `status` / `error`。 |
| `POST` | `/api/session/:id/prompt` | `{"text": "..."}`。 |
| `POST` | `/api/session/:id/cancel` | 停止当前回合。 |
| `POST` | `/api/session/:id/model` | 为该会话选模型 `{provider, model}`。 |
| `GET` | `/api/models` | 可路由模型目录。 |

### 转录节点

插件把 DSH 宽泛的会话事件折叠成四种角色，App 不需要理解 `SessionEventMap`：

| `role` | 来源 | 说明 |
| --- | --- | --- |
| `user` | `user/message` 且 `source.kind == "user"` | 真人输入。 |
| `notice` | `user/message` 的其他来源 | 运行时上下文、技能正文等；App 默认隐藏，可在菜单里打开。 |
| `assistant` | `assistant/message` | 模型输出；流式期间先出现 `streaming` 节点，提交时被正式节点替换。 |
| `tool` | `tool/call` + `tool/result` | 工具调用，按 `callId` 合并，含状态/参数/结果。 |

### SSE 操作

```jsonc
{"type":"reset","nodes":[...],"cursor":42,"header":{...}}
{"type":"op","op":"add","node":{...}}
{"type":"op","op":"update","node":{...}}
{"type":"op","op":"delta","id":"a:live","text":"片段"}
{"type":"op","op":"remove","id":"a:live"}
{"type":"status","phase":"running|idle","turn":3,"reason":"stop"}
{"type":"error","message":"..."}
```

服务端每 15 秒发一条 `: ping` 注释保活；客户端断开即视为取消订阅。

## 验证状态

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| 插件随 DSH 启动并监听 | ✅ 已验证 | `GET /api/health` 返回 `{"ok":true,...}`；插件通过 `plugin_manager install_bundle` 安装在 `desktop` profile，DSH 重启后仍在运行 |
| 令牌鉴权 | ✅ 已验证 | 无令牌 `→ 401`；带 `Bearer` 令牌 `→ 200` |
| DSH 信息上报 | ✅ 已验证 | `/api/info` 返回 `dsh=0.2.2-rc.3`、Electron 44.7.0、Node 24.21.0、网卡列表、Web GUI 地址 |
| 会话列表 / 读取 | ✅ 已验证 | `/api/sessions` 返回 96 行；`/api/session/:id` 返回转录 + 状态 |
| 发 prompt + 流式接收 | ✅ 已验证 | 冒烟测试 `BRIDGE-OK` 往返，15 帧 SSE，~7 秒；续测第二回合 `PONG` 提交为 `a:2:1`，无重复 id |
| 流式去重 | ✅ 已验证 | 第二回合操作序列 `add×4, delta×2, remove×1`：provisional 节点被正式节点精确替换 |
| 取消回合 | ⚠️ 接线已验证 | `POST /cancel` 返回 `{"accepted":true}`；未在真机上制造长回合验证"停得住" |
| 局域网 UDP 发现 | ✅ 已验证 | 本机监听 5181 收到 18 条广播，含主机名/IP/版本 |
| Swift 语法 / 结构 | ⚠️ 部分 | 本地无 Swift 工具链（本机可用空间仅 4.7 GB，装不下 6.4.2 工具链）；只做了自写结构检查 + 人工编译风险审查，**首次真实编译在 CI** |
| IPA 产出 | ⏳ 待 CI | 需要推送仓库后 GitHub Actions 实际构建 |
| 真机连接 | ⏳ 待你测试 | 需要安装 IPA 并在同一 Wi-Fi |

## 安全与边界

- 只绑局域网，不对外；无令牌一律 401（常数时间比较）。
- 插件不改 Harness 状态，只做它被要求做的事：发 prompt、取消回合、选模型。
- **审批与提问仍留在电脑上**：批准工具调用需要完整上下文，手机端只显示「需要你在电脑上确认」。
- 未暴露文件上传、图片 prompt、终端控制。
- ILB（本机回环）可用 `host: 127.0.0.1`，用于模拟器调试。

## 已知限制

- 转录折叠忽略 `turn/*`、`step/*`、`system/message` 等内容（只用于状态帧）。
- 手机发起的会话与电脑上完全等价：会出现在电脑的会话列表里，也会写进持久化日志。
- 工具结果超过 4000 字符会在转发时截断。
- App 中长会话一次性拉取最近 400 条消息对齐的历史页；更早内容需后续分页。

## 开发循环

插件是 profile 里的**目录链接**，改完代码后启停一次即可加载新版本（入口按文件 mtime 做模块缓存失效）：

```
plugin_manager set_plugin target=include:mobile-bridge enabled=false
plugin_manager set_plugin target=include:mobile-bridge enabled=true
```

验证：

```powershell
node tools/bridge-smoke.mjs              # 协议端到端
node tools/beacon-probe.cjs              # 监听 UDP 广播 7 秒
node tools/swift-structure-check.cjs     # Swift 括号/字符串结构
```

