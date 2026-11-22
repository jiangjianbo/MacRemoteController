# AGENTS.md — LAN-Mac-Controller（原名 MacScreen）项目协作规范

本项目是一个「手机遥控 Mac 屏幕」系统：macOS 端把屏幕画面实时投给同网段 Android 手机，
手机可点击屏幕模拟鼠标、向 Mac 当前激活窗口的文本框发送文字/命令，并支持语音输入（本地或大模型转写）。

任何 AI Agent / 开发者在本仓库工作前必须先读本文件，并遵守以下规则。

## 1. 总体架构

```
┌────────────┐   TCP(帧协议)+Bonjour    ┌──────────────┐
│  Android    │ ◄──────────────────────► │ macOS Agent  │
│  手机端      │  发现: _macscreen._tcp    │ 菜单栏/后台    │
└────────────┘  配对: QR / 手动token      └──────────────┘
```

- `mac/MacScreen/`：SwiftPM 工程（Swift 5.6，零第三方依赖，只用系统框架）。
  - `MacScreenCore`（库）：协议、网络、捕获、输入、路由等全部逻辑（可单测）。
  - `MacScreenAgent`（可执行）：入口，`--daemon` 后台模式 / 菜单栏 UI 模式。
  - `PhoneSimulator`（可执行）：模拟手机端的测试客户端，用于端到端测试。
- `android/MacScreenClient/`：Gradle 工程（Kotlin）。
  - `core`：纯 JVM 模块（协议编解码、鼠标映射、语音转写逻辑等），JVM 单测必须全过。
  - `app`：Android 应用（仅当本机有 Android SDK 时才参与构建；无 SDK 时跳过）。
- `scripts/`：统一脚本；仓库根目录有同名快捷入口。
- `logs/`：运行期产物（日志、pid、agent-info.json），不进版本库。
- `task.md`：唯一任务清单。**做任务前从这里取，做完打勾。**
- `操作日志.md`：**每完成一个任务，尾部追加一条日志**（时间、任务、做了什么、测试结果）。

## 2. 核心策略：优先使用操作系统内置能力

凡是操作系统能提供的能力，一律用系统内置组件，不自己造轮子、不引第三方实现：

| 能力 | macOS 方案（内置） | Android 方案（内置/平台标准） |
|---|---|---|
| 屏幕捕获 | CoreGraphics（CGDisplayCreateImage 快照流；10.15+ 有 CGPreflightScreenCaptureAccess 权限预检） | 不适用（看的是 Mac 画面） |
| 图片编码 | NSBitmapImageRep → JPEG | BitmapFactory 解码 |
| 鼠标/键盘注入 | CGEvent（post 到 cghidEventTap，需辅助功能权限） | 不适用 |
| 窗口列表/激活 | CGWindowListCopyWindowInfo + NSRunningApplication/AXRaise | 不适用 |
| 服务发现 | NWListener 自带 Bonjour（`_macscreen._tcp`） | NsdManager |
| 网络 | Network.framework（NWListener/NWConnection） | java.net.Socket |
| 二维码生成 | CoreImage `CIQRCodeGenerator` | 不适用（手机负责扫） |
| 扫码 | 不适用 | CameraX + ML Kit Barcode（平台标准） |
| 语音识别 | 不适用 | 本地：SpeechRecognizer；云端：可配置 REST(OpenAI 兼容) |
| 开机自启 | launchd LaunchAgents plist | 不适用 |
| 持久化 | UserDefaults | SharedPreferences |

例外：协议层为自研的轻量二进制帧（见 §4），两端各自实现并对齐测试。

## 3. 代码规范

- Swift：面向协议 + 依赖注入，**所有涉及系统 API 的组件必须有 Mock 实现**（`MockFrameSource`、
  `MockInputInjector`、`MockWindowService`、`InMemoryTokenStore`、`FakeConnection`、`InMemorySettingsStore`），
  单元测试一律跑在 Mock 上，不依赖真实权限/硬件。
- 纯逻辑（协议编解码、子网计算、坐标映射、launchd plist 生成等）与 IO 严格分离，纯逻辑必须有单测。
- Kotlin：同样约定，`core` 模块禁止依赖 `android.*`（保证 JVM 可测）。
- 不使用 force unwrap 于运行期路径；错误以 `error` 事件或异常上报。
- 注释和日志使用中文，标识符用英文。

## 4. 通信协议（v1）

传输：TCP，一端监听（默认 9700），另一端连接。消息为「帧」：

```
偏移  长度  内容
0    2     magic 'M''S' (0x4D 0x53)
2    1     kind: 0x01=JSON 控制, 0x02=JPEG 视频帧
3    1     flags 保留 (0)
4    4     payload 长度 (uint32 小端)
8    N     payload
```

JSON 控制消息（UTF-8，均为单层对象，请求带 `op`，响应带 `op`；请求可带 `id`，响应原样带回）：

手机→Mac：`hello{token,deviceName}`(必须第一条)、`ping`、`get-status`、`subscribe{video}`、
`set-capture{enabled?,fps?,quality?,maxWidth?}`、`list-windows`、`activate-window{windowId}`、
`mouse{action: click|double|right|down|move|drag|up, x, y}`(x,y 为 0~1 归一化坐标)、
`scroll{dx,dy}`、`type-text{text,submit?}`、`press-key{key,modifiers?}`。

Mac→手机：`hello-ack{ok,protocol,serverName,mock}`、`error{code,message}`、`pong`、
`status{...}`、`windows{list:[{id,title,appName,x,y,w,h,onScreen}]}`、
`screen-info{width,height,pixelWidth,pixelHeight,fps,quality,maxWidth,mock}`、
`capture-state{enabled,permission,mock}`、`ok{action,echo?}`。

安全：连接建立后 5 秒内必须通过 `hello` 鉴权（token 为 32 位 hex，由 Mac 端生成，QR 下发）；
仅允许同网段/回环连接（见 `LANGuard`），公网地址一律拒绝；45 秒无消息断开。

## 5. 测试策略

- Swift：`swift test`（XCTest），目标：全部通过。
- Kotlin：`gradle :core:test`（JVM），目标：全部通过。
- 端到端：`scripts/e2e.sh` —— 以 `--mock-capture --mock-input` 启动真实 Agent（真实 TCP/Bonjour/
  鉴权/路由），用 PhoneSimulator 走完整流程：发现信息→连接→鉴权→收 5+ JPEG 帧→鼠标/文本/按键
  命令→断言 echo→错误 token 被拒。
- 无法自动化验证真实系统权限路径（屏幕录制/辅助功能 TCC 弹窗），在 README 中说明人工验证步骤。

## 6. 常用命令

```bash
./build.sh                 # 统一构建（mac + android 尽力而为）+ 单元测试
./clean.sh                 # 统一清理
./start.sh                 # 开发期启动 Mac 端（后台），打印连接信息
./start.sh --foreground    # 前台运行
./stop.sh                  # 停止
./scripts/e2e.sh           # 端到端测试
cd mac/MacScreen && swift test
```

## 7. 环境备注（本机实测）

- macOS 12.7.6 (x86_64)，Xcode 13.4.1，Swift 5.6.1 → swift-tools-version 用 5.6，不要用 5.7+ 特性。
- JDK 17：`/opt/local/Library/Java/JavaVirtualMachines/openjdk17/Contents/Home`（Gradle 用它，
  系统默认 Java 是 1.8，不能跑 Gradle 9）。
- Android SDK：`~/Library/Android/sdk`；Gradle 9.5.1 在 `/opt/local/bin/gradle`。
- 网络可用（maven central / dl.google.com 可达）。

## 8. 工作流硬规则

1. 所有任务先在 `task.md` 中登记；开始做时标记进行中，完成后打 `[x]`。
2. 每完成一个任务，向 `操作日志.md` **尾部追加**一条记录（日期时间、任务名、改动摘要、测试命令与结果）。
3. 遇到无法快速解决的 bug：分解细化（缩小复现→隔离组件→用 Mock 验证→再合并），并在日志中记录根因。
4. 不得引入第三方 Swift 依赖；Android 仅允许平台标准库与 §2 表中列出的库。
5. 提交信息/日志使用中文。
