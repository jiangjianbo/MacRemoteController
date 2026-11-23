# task.md — LAN-Mac-Controller（原名 MacScreen）任务清单

> 规则：从上往下按序取任务；开始做时把 `[ ]` 改成 `[~]`，完成后改 `[x]` 并在 `操作日志.md` 尾部追加日志。
> 遇到解不开的 bug → 分解细化（缩小复现→Mock 隔离→再合并），记录根因。

## 阶段一：基础设施
- [x] T01 环境探测（macOS/Swift/Java/AndroidSDK/Gradle/网络）与项目脚手架（目录结构）
- [x] T02 AGENTS.md（协作规范+协议规范）、task.md、操作日志.md

## 阶段二：Mac 端（Swift，MacScreenCore + MacScreenAgent）
- [x] T03 SwiftPM 工程（Package.swift：MacScreenCore/MacScreenAgent/PhoneSimulator/Tests）
- [x] T04 通信协议：二进制帧编解码 FrameDecoder/ProtocolFrame + 单元测试（含分片/粘包/坏魔法数恢复）
- [x] T05 JSON 消息层：Request 解析 / ServerEvent 构造 / WindowInfo / ScreenInfo + 单元测试
- [x] T06 局域网守卫 LANGuard：同网段校验（v4 子网含、v6 /64、回环、公网拒绝）+ 单元测试（注入接口表）
- [x] T07 配对：令牌生成/存储（TokenStore）+ CoreImage CIQRCodeGenerator 二维码 + 单元测试（QR 可解码回读）
- [x] T08 连接抽象 Connection + NWConnectionAdapter（Network.framework 适配，可被 FakeConnection 替换）
- [x] T09 会话 Session：鉴权状态机（hello 超时/错误 token 拒绝/LAN 校验）、心跳看门狗、视频订阅、背压丢帧 + FakeConnection 单元测试
- [x] T10 TCP 服务器 AgentServer（NWListener + Bonjour `_macscreen._tcp` 广播）
- [x] T11 窗口服务 WindowService（CGWindowListCopyWindowInfo 列表 + NSRunningApplication/AXRaise 激活）+ 模型/解析单测 + Mock
- [x] T12 输入注入 InputInjector（CGEvent：鼠标 down/move/drag/up/click/double/right、unicode 文本、按键+修饰键、滚轮）+ 坐标/键值映射单测 + Mock（记录动作）
- [x] T13 屏幕捕获：FrameSource 协议 + CGDisplayCreateImage 快照流实现 + MockFrameSource（CGContext 画测试图）+ JPEG 编码（NSBitmapImageRep，含缩放）+ 权限预检降级 + 单元测试（Mock 源产帧/JPEG 魔数）
- [x] T14 命令路由 CommandRouter：全部 op 编排（鉴权后指令分发、归一化坐标→屏幕坐标、echo 回带）+ 全 Mock 单元测试
- [x] T15 设置存储（UserDefaults/InMemory）+ 开机启动 LoginItemManager（launchd LaunchAgents plist 生成/加载/卸载）+ 单元测试（临时目录+MockProcessRunner）
- [x] T16 入口与运行时：--daemon 后台模式 / 菜单栏 UI（配对二维码窗口、投屏开关、开机启动开关、退出）+ 日志系统 + agent-info.json
- [x] T17 PhoneSimulator 模拟手机客户端（连接/鉴权/收帧/发命令/断言，支持 --bad-token 反向用例）

## 阶段三：脚本与端到端
- [x] T18 统一脚本：build.sh / clean.sh（根目录快捷入口）+ 开发期 start.sh / stop.sh
- [x] T19 端到端测试 e2e.sh：真实 Agent（mock 捕获+mock 输入）↔ PhoneSimulator 全链路（鉴权→视频帧→鼠标→文本→按键→set-capture→错误 token 拒绝），全部通过

## 阶段四：Android 端（Kotlin）
- [x] T20 Gradle 工程：settings/build 脚本，`:core` 纯 JVM 模块（无 SDK 也可测试），`:app` 仅检测到 SDK 时纳入
- [x] T21 core：帧协议编解码（Kotlin 版，与 Swift 端对齐）+ 单元测试（互操作向量：与 Swift 产出字节一致）
- [x] T22 core：消息层（请求构造/响应解析）+ 单元测试
- [x] T23 core：鼠标映射 MouseMapper（letterbox 归一化）+ 手势分类器 GestureClassifier（单击/双击/长按右键/拖动）+ 单元测试
- [x] T24 core：语音 WavEncoder（PCM→WAV）+ CloudTranscriber（OpenAI 兼容 multipart / 通用 JSON，可配置 URL/Key/模型）+ 单元测试（FakeHttpPoster）
- [x] T25 core：MacConnection 连接客户端（Socket 抽象 Transport，可注入管道流测试）+ 单元测试（hello 握手/收帧/错误 token）
- [x] T26 app：AndroidManifest、ClientApp、MainActivity（发现列表/手动/扫码连接）
- [x] T27 app：ScreenActivity（MJPEG VideoView 渲染 + 触摸→click/right/drag、窗口列表激活、文本发送、断线重连）
- [x] T28 app：语音（本地 SpeechRecognizer / 云端录音→WAV→CloudTranscriber）+ 设置页（引擎、云端 URL/Key/模型、采集参数）
- [x] T29 app：QR 扫码配对（CameraX + ML Kit）与手动配对兜底
- [x] T30 Android 构建验证：`:core` 单测通过（38 tests）；`:app` assembleDebug 通过（补装 cmdline-tools + android-35 + build-tools 35）

## 阶段五：收尾
- [x] T31 README.md（使用说明、权限说明、人工验证清单、脚本说明）
- [x] T32 全量回归：swift test（79）+ :core:test（38）+ e2e 复跑（15 断言），全部通过，汇总操作日志

## 阶段六：增强
- [x] T33 手机扫码下载：Mac 端内置极小 HTTP 文件分享服务（LAN 守卫 + 分块流式发送），
      菜单栏二维码：默认自动发现构建产物 APK（dist/ 或 Android 输出目录），
      也支持选择任意文件分享；e2e 增加 HTTP 下载/404 断言
- [x] T34 手势语义重整：双指捏合=本地缩放画面（锚点缩放，不发 Mac）、缩放态单指拖动=平移画面（不发 Mac）、
      两种状态点按仍发单击 Mac（缩放态经 normalizedZoomed 逆映射）、未缩放拖动仍发 Mac 拖动；
      缩放态双指接管时若 Mac 鼠标按下中先补发 up 防卡键；输入框提示改「请输入」。
      含 VideoView 锚定公式 bug（anchoredPan）与 clampPan zoom 感知语义两处修复 + 单测。
- [x] T35 投屏体验四项：①窗口列表只显示标题（无标题回退应用名）且 item 限 2 行省略，点击激活（原有）；
      ②修复熄屏解锁后画面卡「等待画面」——根因是深睡时 Handler ping 被推迟超过 Mac 端 45s 空闲
      看门狗、连接被掐断而客户端无重连：onResume 断线重连/帧停重订阅 + onClosed 2s 后自动重连一次；
      ③缩放态右下角「还原」按钮（复位 zoom/pan，非缩放态隐藏）；④投屏页沉浸式全屏
      （隐藏系统状态栏/导航栏），避免缩放平移后 Mac 菜单栏被 Android 顶栏遮挡无法点击。
- [x] T36 本地语音识别环境自动诊断与安装指导：新增 VoiceDiagnostics 能力发现
      （queryIntentServices 找 RecognitionService 提供者 + voice_recognition_service 默认服务 +
      启用/冻结状态 + Google 组件针对性探测），按「无服务 / 有服务未设默认或被禁用 / 可用」
      三分支给出指导；ScreenActivity 按话筒前拦截并弹诊断对话框（去处理/改用云端一键跳转）；
      SettingsActivity 提示改为动态诊断摘要；识别错误映射补 NETWORK_TIMEOUT 与冻结提示。
- [x] T37 界面改造与多语言：①Android 端多语言（values/strings.xml 英文默认 + values-zh
      简体中文，101 个 key，自动跟随系统语言，其余语言回退英文；语音识别语言同步跟随系统）；
      全部用户可见文案 i18n（含 VideoView 等待提示、QR 扫码、语音诊断、错误 Toast），
      图标按钮附 contentDescription；②投屏页改透明浮动工具栏（纯图标 ⏎≡🎤▦⟳✕，
      缩放态右端动态 ↺ 还原），单行输入框占大面积 + ➤ 图标发送；③文本超 3 行（StaticLayout
      计算自动回绕）点按自动进全屏多行编辑模式（⏎回车开关/⇲回看/🎤语音/➤发送高亮默认按钮），
      长按文本框直接进语音；⇲ 回看自动收键盘；语音文本永远插入光标位置；
      修复 Button 主题 88dp 最小宽把 ✕ 挤出屏（setMinWidth(0)）、EditText onClick 被光标
      放置吞掉（改 OnTouchListener ACTION_UP 后置）、程序化回填文本触发 TextWatcher 弹回
      （paneSyncing 抑制）三处缺陷。e2e 实机验证：英文/中文双 locale 界面、7 按钮、
      自动多行切换、回看收键盘、旋转双向（竖→横→竖）、窗口列表选择激活、长按语音诊断
      对话框、捏合缩放 ↺ 出现/还原消失、多行发送清空。
- [x] T38 工具栏图标语义化重绘：Unicode 字形全面替换为自绘 VectorDrawable（24dp 视口、
      白色线框 stroke 1.4~2 round cap/join，跨机型渲染一致）， ImageButton +
      setImageTintList 动态着色。按需求重绘四枚：窗口列表=2x2 四窗口平铺（各带标题栏）、
      断开连接=开口相向链环+断开斜线（弃用 ✕，两轮迭代：闭合圆环像 % → 改开口链环、
      斜线收拢）、还原缩放=窗口框内 X+四角展开箭头（缩放态动态出现）、多行模式=笔记本纸；
      其余同步统一：回车↵、麦克风、纸飞机发送、旋转弧箭头+实心三角头、回看眼睛；
      多行模式发送按钮蓝底白图标高亮，语音录音态红色 tint。修复查看模式发送按钮
      白 tint 在白色输入条上不可见（改深色 0xFF333333）。e2e 目视验收：查看模式
      6 图标 + 深色发送、多行模式 4 图标 + 蓝底发送、pinch 缩放 ↺ 出现/还原消失，
      全部清晰无渲染异常；:core:test 47 tests 通过，APK 同步 dist。
- [x] T39 iOS 客户端：把 Android 端功能迁移到 iOS（部署目标 iOS 13.0，只用 13 时代
      API 不用 14+ 特性；SwiftUI + UIKit 组件混编，AppDelegate 生命周期）。结构：
      ios/CoreLogic 独立 Swift Package（纯逻辑可 macOS swift test：MouseMath 坐标映射、
      GestureClassifier 手势分类、PairingUri 配对解析、RequestsBuilder 请求构造、
      VoiceCodec WAV/multipart）；app 工程引用 CoreLogic 源文件 + mac 端
      ProtocolFrame.swift/Messages.swift 协议层复用。功能对齐 Android：Bonjour 发现
      （NWBrowser _macscreen._tcp）、扫码配对（AVCaptureMetadataOutput）、手动连接、
      MJPEG 投屏渲染（UIImageView 换帧）、单击/双击/长按右键/拖动/捏合缩放平移
      （本地变换+归一化坐标发送）、浮动工具栏 7 按钮（SF Symbols iOS 13 可用图标）、
      单行输入条 >3 行自动切全屏多行（UITextView）、长按文本框进语音、本地
      （SFSpeechRecognizer）+ 云端（WAV multipart OpenAI 兼容）双引擎、语音插光标、
      窗口列表激活、15s ping/断线重连/帧停重订阅、中英双语、e2e（模拟器连 mock
      agent 9730 全功能自动化断言）。
      完成（2026-11-23）：CoreLogic 29 tests 全过；xcodebuild 模拟器构建通过；
      e2e 全绿（connected→帧流 5fps→mouse click 0.5,0.5→type-text 中文→windows→done
      frames=27，mock agent 日志确认设备连接与视频订阅）；截图目视验收通过（深色
      mock 画面居中、底部 6 图标工具栏、白色输入条+纸飞机）。过程中修 4 个 bug：
      握手超时与 queue 回调竞态致 force-unwrap 崩溃（NSLock+只完成一次去重）、
      e2e token 用错（agent 未采纳 --token，改读 info.json 真值）、SwiftUITextView
      representable 在 iOS 13~15 不采 intrinsicContentSize 致输入条撑满全屏白屏
      （改 SwiftUI 层行数回调驱动 .frame(height:)）、纸飞机黑色图标浮在深色画布
      不可见（白底提到 HStack 整条）。新增 scripts/ios-build.sh 并接入 build.sh/
      clean.sh，dist/MacScreenClient.app（模拟器包）。真机部署：Xcode 自动签名。
- [x] T40 窗口列表看不到全屏 Space 应用（用户反馈：最大化屏幕的 Mac 应用
      不在手机窗口列表中，只能手动切屏才出现）。根因：CGWindowService 用
      CGWindowListCopyWindowInfo(.optionOnScreenOnly) 只枚举当前 Space，
      全屏应用独占独立 Space 故整个漏掉。修复：改 .optionAll 枚举全部
      Space 的窗口（过滤逻辑抽纯函数 filterWindows 供单测），非当前 Space
      窗口由既有 onScreen 字段标记；激活路径不变（app.activate + AXRaise
      对其他 Space 窗口会自动切换）。真实系统验证：此前仅 2 个窗口可见，
      修复后 17 个（iTerm2/微信/Typora/Edge/GitHub Desktop 等全出现）。
      新增 WindowServiceTests 4 项，mac 端 91 tests 全过；dist 已重建。
      注意：运行中的 agent 需重启才会用上新二进制（重建后首次投屏需重新
      勾选屏幕录制授权）。
