# LAN-Mac-Controller

（原名 MacScreen）局域网内把 Mac 屏幕投到 Android 手机，并在手机上控制 Mac：模拟鼠标（点击/双击/右键/拖动）、向 Mac 焦点窗口发送文字（键盘输入或语音转文字）、激活指定窗口。仅接受**同一局域网同网段**的连接，公网一律拒绝。

## 组成

| 端 | 技术 | 位置 |
|---|---|---|
| Mac 端 | Swift 5.6 / SwiftPM（Network.framework、CGDisplay、CGEvent、CoreImage、launchd、NSMenu） | `mac/MacScreen/` |
| Android 端 | Kotlin（`:core` 纯 JVM + `:app` Android；NsdManager、SpeechRecognizer、CameraX + ML Kit） | `android/MacScreenClient/` |
| 脚本 | 统一 build/clean、开发期 start/stop、端到端测试 | `scripts/` + 根目录垫片 |

设计原则：**尽量使用操作系统内置能力，不自己造轮子**。录屏用 CGDisplayCreateImage 快照流，鼠标键盘用 CGEvent 注入，服务发现用 Bonjour/NsdManager，扫码用 CoreImage / ML Kit，开机启动用 launchd LaunchAgents，语音转文字用手机内置 SpeechRecognizer 或用户自配的云端大模型接口。

## 快速开始（Mac 端）

```bash
./build.sh          # 编译 + 单测 + （有 SDK 时）Android 构建
./start.sh          # 开发期启动（默认 mock 模式，MACSCREEN_MOCK=0 关闭）
./stop.sh           # 停止
./clean.sh          # 清理全部构建产物
```

启动后菜单栏出现 MacScreen 图标（或以 `--daemon` 后台运行），连接信息打印在终端和 `logs/agent-info.json`：

```json
{ "pid": ..., "port": 9700, "token": "<32位hex>", "hosts": ["192.168.31.x"], "mock": {...},
  "shareUrl": "http://192.168.31.x:9701/file", "shareFile": "/path/to/LAN-Mac-Controller-debug.apk" }
```

- **扫码配对**：菜单栏「配对二维码」→ 手机 App「扫码连接」对准扫。
- **自动发现**：手机 App「自动发现」列表会列出 Bonjour 广播的 `_macscreen._tcp` 服务。
- **手动**：在手机上输入 IP / 端口 / 令牌。
- **手机扫码下载 APK**：菜单栏「手机扫码下载 APK…」弹出二维码窗口，手机浏览器扫码（或访问该 URL）即可经局域网直接下载客户端 APK，无需数据线/sideStore。默认自动发现构建产物 APK（优先 `dist/LAN-Mac-Controller-debug.apk`，其次 Android 输出目录）；窗口下方「选择文件…」按钮可改为分享**任意文件**（PDF/zip 均可），选完文件名/大小即时刷新，下载地址不变。

### Mac 端运行方式

- **日常使用**：双击 `dist/LAN-Mac-Controller.app`（或 `open dist/LAN-Mac-Controller.app`）。这是标准应用包（LSUIElement 菜单栏应用），由 LaunchServices 直接启动，**没有终端窗口**；菜单栏出现 🖊🖥 图标。注意：裸可执行文件（如 `dist/MacScreenAgent`）双击时 macOS 会把它交给 Terminal.app 运行从而出现黑色终端窗口，这是裸 Unix 可执行文件的启动行为，与 debug/release 无关 —— 请使用 .app 包。
- **开发调试**：`scripts/start.sh`（debug 构建后台运行，详见下文）；或双击 `dist/LAN-Mac-Controller-debug.app`。
- **版本**：构建同时产出 release 与 debug 两套：`LAN-Mac-Controller.app`（release）与 `LAN-Mac-Controller-debug.app`（debug，identifier `com.macscreen.agent.debug`，可与 release 版共存便于对比）。两者均为 universal 双架构。
- **首次运行授权**：.app 包与裸二进制的 TCC 身份不同，且 ad-hoc 签名每次重建都会变化 —— 从裸二进制切换到 .app 包（或每次重新构建后）首次投屏需在 系统设置 → 隐私与安全性 → 屏幕录制 重新勾选授权，并完全重启应用。

### Mac 端运行选项（Agent 直调）

```
macscreen-agent [--daemon] [--port N] [--mock-capture] [--mock-input]
                [--no-mock-fallback] [--no-bonjour] [--no-fileshare]
                [--info-file PATH] [--log-file PATH]
```

- **芯片支持**：`dist/MacScreenAgent` 为 universal 双架构（Intel x86_64 + Apple Silicon arm64），M1/M2/M3 等 Apple 芯片 Mac 原生运行，无需 Rosetta；代码仅用跨架构系统 API（CGDisplayCreateImage 截屏、CGEvent 注入、launchctl 开机启动），协议层显式定宽字节序，两端互通不受架构影响。某架构构建失败时 build.sh 自动回退单架构产物。

- `--mock-capture` / `--mock-input`：用内置 Mock 替代真实录屏/输入注入（无权限或调试用）。
- 默认策略：真实捕获不可用（缺屏幕录制权限）时自动降级到 Mock，可用 `--no-mock-fallback` 禁止。
- `--no-fileshare`：关闭文件分享服务（默认开启，找到可分享文件时才实际提供下载）。

### 开机启动 / 后台

- `--daemon`：无 UI 后台模式（配合 launchd/手工）。
- 菜单栏勾选「开机启动」：写入 `~/Library/LaunchAgents/com.macscreen.agent.plist`（RunAtLoad）。

## 快速开始（Android 端）

```bash
./android-build.sh            # :core 单测（无 SDK 也可）
./android-build.sh --with-app # 连 :app assembleDebug（需 Android SDK）
```

产物：`android/MacScreenClient/app/build/outputs/apk/debug/app-debug.apk`。

环境要求：JDK 17（脚本自动探测 `JAVA_HOME`/常见路径）、Android SDK Platform 35 + Build-Tools 35（AGP 8.13；`sdkmanager "platforms;android-35" "build-tools;35.0.0"` 可补装）、Gradle 9+。

手机操作：

1. 安装 APK，进入主界面 → 用「自动发现」/「扫码」/ 手动填 IP+端口+令牌 →「连接」。
2. 投屏页手势（鼠标类手势发给 Mac，缩放类手势只在本地变换画面、不发指令）：
   - 未缩放：点按=单击、双击=双击、长按=右键、拖动=按住拖动（letterbox 黑边区域不响应）。
   - 双指捏合/张开：缩放画面（以捏合中心为锚点），不发鼠标；缩放态浮动工具栏右端出现「↺ 还原」按钮，点按复位到全屏无缩放。
   - 缩放后单指拖动：平移画面查看细节（越界自动钳制，不发鼠标）；再点按仍=单击 Mac，坐标按缩放逆映射。
   - 投屏页为沉浸式全屏（隐藏系统状态栏/导航栏），缩放平移后 Mac 菜单栏移到屏幕最顶部也能点到；从顶部下滑可临时呼出状态栏。
3. 画面底部是透明浮动工具栏（纯图标 + 无障碍语音描述），从左到右：⏎ 回车开关、≡ 多行编辑、🎤 语音、▦ 窗口列表、⟳ 横竖屏、✕ 断开；缩放态右端动态多出 ↺ 还原。
   工具栏下方单行输入框占大部分面积，右侧 ➤ 图标发送文字到 Mac 当前焦点文本框；⏎ 亮绿时发送后附 Return。
   - 文本超过 3 行（含自动回绕）时：点按文本框自动切到全屏多行编辑模式。
   - 长按文本框直接进入语音输入。
4. 多行编辑模式：全屏编辑框 + 顶部工具栏（⏎ 回车开关、⇲ 回看、🎤 语音、➤ 发送[高亮默认按钮]）；语音识别文本永远插入到光标位置。
   ⇲ 回到查看模式（自动收起键盘看画面）；查看模式点文本框，内容超 3 行又自动回多行编辑。
5. ▦ 窗口列表：列出 Mac 可见窗口标题（限 2 行省略），选择即激活该窗口（聚焦）。
6. 🎤 语音输入：设置里选「本地识别」（Android 内置离线）或「云端转写」（OpenAI 兼容 `/audio/transcriptions` 或直接 POST WAV，可配 URL/Key/模型）；识别语言自动跟随系统语言。
   本地识别会自动诊断环境（有无语音识别服务、系统默认服务、组件是否被禁用/冻结），不可用时弹对话框给出针对性指导并支持「去处理」/「改用云端」一键跳转。国产机（HyperOS 等）用本地识别需：谷歌框架 + Google「Speech Recognition & Synthesis」（com.google.android.tts）+ 系统默认语音识别选 Google + 给组件解除省电冻结；Google 识别服务端需可访问谷歌网络，大陆网络建议直接用云端转写。
7. 多语言：界面自动跟随系统语言（内置简体中文与英文，其余语言回退英文）；全部按钮图标化并附 contentDescription（无障碍服务可读）。
8. 熄屏休眠再解锁后自动重连恢复画面（熄屏期间 ping 被系统推迟，连接可能被 Mac 端空闲看门狗掐断）。

## 协议摘要

二进制帧（两端字节级一致，含互操作单测向量）：

```
magic 'MS'(4D 53) | kind(01=JSON, 02=JPEG) | flags(00) | u32 LE length | payload
```

操作（JSON，含 `id` 回带）：`hello{token,deviceName}`（5s 握手超时）→ `hello-ack`；`ping/get-status/subscribe{video}/set-capture/list-windows/activate-window{windowId}/mouse{action,x,y 归一化}/scroll/type-text{text,submit}/press-key{key,modifiers}`；错误返回 `error{code,message}`。

QR 内容：`macscreen://connect?host=..&port=..&token=..&name=..`。

安全：连接先过 LANGuard（仅回环、RFC1918 同网段 v4、同 /64 链路本地 v6 放行），再验 hello token；视频帧背压丢弃（最多积压 3 帧），45s 空闲断开。

文件分享（扫码下载）：独立极小 HTTP 服务，端口 = 主端口 + 1，仅支持 `GET/HEAD /file` 单一路径，分块流式发送（256KB/块）；与主服务共用同一 LANGuard 策略（公网/异网段一律拒绝），只分享当前设定的单个文件，中文文件名经 RFC 5987 `filename*=UTF-8''` 编码下发。

## 测试

| 层 | 命令 | 当前状态 |
|---|---|---|
| Mac 单测 | `cd mac/MacScreen && swift test` | 86 tests, 0 failures（含 FileShare 回环下载集成测试） |
| Android core 单测 | `scripts/android-build.sh`（`:core:test`） | 38 tests, 0 failures |
| 端到端 | `./scripts/e2e.sh`（真实 TCP：mock Agent ↔ PhoneSimulator） | HTTP 下载 1 + 正向 13 + 反向 2 断言全过 |

Mock 策略：两端核心逻辑均可在无硬件/无权限环境下验证（MockFrameSource、MockInputInjector、MockWindowService、FakeConnection、PipeTransport、FakeHttpPoster 等）。

## 人工验证清单（自动化覆盖不到的部分）

- [ ] Mac 端「系统设置 → 隐私与安全性 → 屏幕录制」授权后，真实画面出现在手机。
- [ ] 菜单栏二维码窗口可被手机扫中并一键连接。
- [ ] 手机浏览器扫「手机扫码下载 APK」二维码，经局域网下载 APK 并可安装（对照文件大小）。
- [ ] 手机点击能激活 Mac 上的目标窗口并落到正确位置（对照 Mac 屏幕验证坐标）。
- [ ] 文字发送到 Mac 焦点输入框（试 Notes/浏览器地址栏），含中文与回车提交。
- [ ] 本地语音识别装了离线中文包后可用；云端转写填好 URL/Key 后可用。
- [ ] 勾选「开机启动」后重启 Mac，Agent 自动运行。
- [ ] 手机离开网段（换热点）后连接被拒绝/断开，Mac 日志出现 LAN 拒绝记录。

## Android 端闪退排查

App 内置全局崩溃捕获：任何未捕获异常会先把堆栈追加写入 crash.log（内部与外部应用专属目录各一份），
无需 adb 即可取证。手机上路径：`Android/data/com.macscreen.client/files/crash.log`
（可经文件管理器/USB 拷出），把内容反馈即可定位问题。

## 已知限制

- macOS 12 上 SpeechRecognizer 的离线识别在手机侧完成，与 Mac 版本无关；云端转写需要网络。
- 屏幕捕获是快照流（可调 fps），非 60fps 低延迟串流；适合控制场景。
- **空闲断开规则**：会话 45 秒无活动会被 Mac 端断开；「活动」包括手机发来的任何请求
  （手势/文字/ping）与视频帧的持续外发——手机挂在不操作纯观看不会掉线。手机端另有
  15 秒一次的 ping 保活。
- LAN 校验基于本机接口地址推断网段，多网卡/VPN 场景以实际路由为准（公网地址仍一律拒绝）。
- **屏幕录制权限归属规则**（macOS 10.15+）：从终端启动 Agent 时，系统把权限归属到**终端应用本身**——需在「系统设置 → 隐私与安全性 → 屏幕录制」勾选你的终端（Terminal/iTerm 等）；用 Finder 双击或 launchd 启动时才归属到 `dist/MacScreenAgent` 二进制。勾选后必须**完全退出并重启** Agent 才生效。无权限时 Agent 会降级为 Mock 视频源并在日志中给出上述指引；`--no-mock-fallback` 可改为直接报错。
- **国产机型语音识别差异**（小米/红米 HyperOS、华为鸿蒙等）：无谷歌移动服务，系统
  SpeechRecognizer 要么不存在、要么由厂商私有服务承接（小米为小爱语音，部分需先在
  小爱同学中同意语音协议，且实际走厂商云端而非本地）。App 对此有前置检测与明确提示，
  并对厂商服务"无响应卡死"做了 8 秒兜底。**国产机型推荐直接使用云端大模型转写**。
- dist 产物为 ad-hoc 签名：**每次重新构建后二进制身份会变化，屏幕录制授权需要重新勾选一次**；如需免重签可用自己的证书签名（`codesign --force --sign <你的身份> dist/MacScreenAgent`）。
