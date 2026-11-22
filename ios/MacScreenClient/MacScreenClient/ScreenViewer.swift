import SwiftUI
import UIKit

/// 投屏主界面（对齐 Android ScreenActivity）：
/// 画布 + 底部透明浮动工具栏 + 单行输入条 + 语音覆盖层 + 窗口列表 sheet + 全屏多行编辑。
struct ScreenViewer: View {
    @EnvironmentObject var session: SessionModel
    @EnvironmentObject var settings: AppSettings

    @State private var inputText = ""
    @State private var multilineMode = false
    @State private var showWindows = false
    @State private var voice = VoiceManager()

    /// 输入条字体（与 UITextView 内部一致，用于回绕行数计算）
    private let inputFont = UIFont.systemFont(ofSize: 15)

    var body: some View {
        ZStack {
            if multilineMode {
                MultilineEditor(text: $inputText, voice: voice, onExit: { multilineMode = false })
                    .environmentObject(session).environmentObject(settings)
            } else {
                viewerPane
            }
        }
        .onAppear { session.connect() }
        // toast（错误/提示）
        .toast(message: $session.toast)
    }

    // MARK: 查看模式

    private var viewerPane: some View {
        ZStack(alignment: .bottom) {
            ScreenCanvas(session: session)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 4) {
                toolbar
                InputBar(text: $inputText, voice: voice,
                         onMultiline: { multilineMode = true },
                         onSend: sendInput)
            }
            .padding(.bottom, 2)

            if session.recording { VoiceOverlay(voice: voice) }
        }
        .sheet(isPresented: $showWindows) {
            WindowsSheet(windows: session.windows) { win in
                session.send(Requests.activateWindow(win.id))
                showWindows = false
            }
        }
    }

    // MARK: 浮动工具栏（SF Symbols 均为 iOS 13 可用，语义与 T38 Android 矢量图标一致）

    private var toolbar: some View {
        HStack(spacing: 0) {
            iconButton("arrow.turn.down.left", "cd_submit", tint: settings.voiceSubmit ? .green : .white) {
                settings.voiceSubmit.toggle()
            }
            iconButton("doc.text", "cd_multiline", tint: .white) { multilineMode = true }
            iconButton("mic", "cd_voice", tint: session.recording ? Color.red : .white) {
                voice.toggle(session: session, settings: settings)
            }
            iconButton("square.grid.2x2", "cd_windows", tint: .white) {
                session.send(Requests.listWindows())
                showWindows = true
            }
            iconButton("arrow.clockwise", "cd_rotate", tint: .white) { rotateScreen() }
            iconButton("wifi.slash", "cd_disconnect", tint: .white) { session.disconnect() }
            Spacer(minLength: 0)
            if session.zoomed {
                iconButton("arrow.down.right.and.arrow.up.left", "cd_reset_zoom", tint: .white) {
                    NotificationCenter.default.post(name: .macscreenResetZoom, object: nil)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.25))   // 半透明衬底，浅色画面上白图标也可读
    }

    private func iconButton(_ systemName: String, _ labelKey: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .accessibility(label: Text(LocalizedStringKey(labelKey)))
    }

    /// 横竖屏切换：iOS 13 无公开 API，用广泛使用的 orientation 写入 + 尝试旋转。
    private func rotateScreen() {
        let current = UIDevice.current.orientation
        let target: UIInterfaceOrientation =
            current.isLandscape ? .portrait : .landscapeRight
        UIDevice.current.setValue(target.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }

    // MARK: 输入发送（对齐 Android：typeText(submit: voiceSubmit)，发送后清空）

    private func sendInput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.send(Requests.typeText(text, submit: settings.voiceSubmit))
        inputText = ""
    }
}

/// 单行输入条：占用剩余宽度，右侧纸飞机发送；文本超 3 行（含回绕）自动切多行模式。
struct InputBar: View {
    @EnvironmentObject var session: SessionModel
    @EnvironmentObject var settings: AppSettings
    @Binding var text: String
    var voice: VoiceManager
    var onMultiline: () -> Void
    var onSend: (String) -> Void

    @State private var multilineRequested = false
    /// 输入条高度：空 1 行起，3 行封顶（>3 行直接切多行模式）。SwiftUI 对
    /// representable 的 UITextView 不采 intrinsic 尺寸（iOS 13~15），必须显式 frame。
    @State private var barHeight: CGFloat = 34
    private let font = UIFont.systemFont(ofSize: 15)

    var body: some View {
        HStack(spacing: 4) {
            GrowingTextField(text: $text, font: font,
                             onLinesChanged: { lines in
                                 // >3 行（含回绕）自动切全屏多行编辑（对齐 Android）
                                 if lines > 3 { onMultiline() }
                                 let insets = CGFloat(16)   // UITextView textContainerInset 上下各 8
                                 barHeight = min(CGFloat(lines), 3) * font.lineHeight + insets
                             },
                             onLongPress: {
                                 voice.toggle(session: session, settings: settings)
                             },
                             onCommit: { onSend(text) })
                .frame(height: barHeight)

            Button {
                onSend(text)
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17))
                    .foregroundColor(Color.black.opacity(0.8))
                    .frame(width: 36, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibility(label: Text(LocalizedStringKey("cd_send")))
        }
        .padding(.horizontal, 4)
        // 整条白色输入区（对齐 Android BottomBar）：纸飞机图标是黑色的，
        // 浮在深色画布上会不可见，白底必须覆盖到按钮。
        .background(Color.white)
    }
}

/// 通知名：还原缩放按钮 → CanvasUIView（Representable 与 SwiftUI 解耦）
extension Notification.Name {
    static let macscreenResetZoom = Notification.Name("macscreen.resetZoom")
}

/// 轻量 toast：状态行上方浮层，2.5s 自动消失。
struct Toast: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            if let msg = message {
                Text(msg)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(16)
                    .padding(.top, 60)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { message = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2))
    }
}

extension View {
    func toast(message: Binding<String?>) -> some View {
        modifier(Toast(message: message))
    }
}
