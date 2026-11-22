import SwiftUI
import UIKit

// MARK: - 自增高文本输入（单行输入条用；行为对齐 Android EditText+StaticLayout）

/// 自增高 UITextView：iOS 13 的 UIViewRepresentable 无 sizeThatFits 协议方法，
/// 用 intrinsicContentSize 驱动 SwiftUI 布局（1 行起，3 行封顶；与 InputBar 的
/// >3 行切多行模式衔接）。宽度未定时按 300 估高，layoutSubviews 定宽后重报。
final class GrowingUITextView: UITextView {
    var maxLines: CGFloat = 3
    private var lastReportedHeight: CGFloat = -1

    override var intrinsicContentSize: CGSize {
        let font = self.font ?? .systemFont(ofSize: 15)
        let lineHeight = font.lineHeight
        let width = bounds.width > 8 ? bounds.width : 300
        let fitting = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: UIView.noIntrinsicMetric, height: min(fitting, lineHeight * maxLines))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = intrinsicContentSize.height
        if height != lastReportedHeight {
            lastReportedHeight = height
            invalidateIntrinsicContentSize()
        }
    }
}

/// UITextView 包装：scrollEnabled=false 自动增高；回绕行数经 Core Text 计算；
/// 长按进入语音；return 键仅换行（发送走纸飞机按钮，与 Android 一致）。
struct GrowingTextField: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont
    var onLinesChanged: (Int) -> Void
    var onLongPress: () -> Void
    var onCommit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let v = GrowingUITextView()
        v.font = font
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.delegate = context.coordinator
        context.coordinator.parent = self
        let long = UILongPressGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.longPressed(_:)))
        long.minimumPressDuration = 0.45
        v.addGestureRecognizer(long)
        context.coordinator.observeVoice(into: v)
        return v
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text, !context.coordinator.syncing {
            // 程序化回填（多行模式互通）时抑制回调风暴
            context.coordinator.syncing = true
            view.text = text
            context.coordinator.syncing = false
            view.invalidateIntrinsicContentSize()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextField?
        var syncing = false
        private var voiceObserver: NSObjectProtocol?

        /// 语音识别结果插入光标位置（UITextView.insertText 天然插在光标处）。
        func observeVoice(into textView: UITextView) {
            voiceObserver = NotificationCenter.default.addObserver(
                forName: .macscreenVoiceResult, object: nil, queue: .main) { [weak textView] note in
                guard let text = note.userInfo?["text"] as? String, let tv = textView else { return }
                tv.insertText(text)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let parent = parent else { return }
            syncing = true
            parent.text = textView.text
            syncing = false
            textView.invalidateIntrinsicContentSize()
            parent.onLinesChanged(GrowingTextField.wrappedLineCount(textView: textView))
        }

        @objc func longPressed(_ g: UILongPressGestureRecognizer) {
            if g.state == .began { parent?.onLongPress() }
        }

        deinit {
            if let o = voiceObserver { NotificationCenter.default.removeObserver(o) }
        }
    }

    /// 回绕行数：按输入框实际宽度 + 字体行高（等价 Android StaticLayout）。
    static func wrappedLineCount(textView: UITextView) -> Int {
        let width = textView.bounds.width - textView.textContainerInset.left
            - textView.textContainerInset.right
            - textView.textContainer.lineFragmentPadding * 2
        guard width > 8, !textView.text.isEmpty else { return 1 }
        return countLines(text: textView.text, width: max(width, 20),
                          font: textView.font ?? .systemFont(ofSize: 15))
    }

    static func countLines(text: String, width: CGFloat, font: UIFont) -> Int {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)
        return max(1, Int(ceil(rect.height / font.lineHeight)))
    }
}

// MARK: - 全屏多行编辑模式（对齐 Android editPane）

/// 顶部工具栏（回车开关/返回查看/语音/发送高亮）+ 全屏编辑框。
struct MultilineEditor: View {
    @EnvironmentObject var session: SessionModel
    @EnvironmentObject var settings: AppSettings
    @Binding var text: String
    var voice: VoiceManager
    var onExit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                iconButton("arrow.turn.down.left", "cd_submit",
                           tint: settings.voiceSubmit ? .green : Color.white.opacity(0.7)) {
                    settings.voiceSubmit.toggle()
                }
                iconButton("eye", "cd_singleline", tint: .white) { onExit() }
                iconButton("mic", "cd_voice",
                           tint: session.recording ? .red : Color.white.opacity(0.7)) {
                    voice.toggle(session: session, settings: settings)
                }
                Spacer(minLength: 0)
                Button {
                    sendAll()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22).padding(.vertical, 7)
                        .background(Color(red: 0.12, green: 0.53, blue: 0.90))   // 高亮默认按钮蓝
                        .cornerRadius(6)
                }
                .accessibility(label: Text(LocalizedStringKey("cd_send")))
                .padding(.trailing, 4)
            }
            .padding(.vertical, 6)

            FullscreenTextView(text: $text)
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }

    private func sendAll() {
        let value = text
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.send(Requests.typeText(value, submit: settings.voiceSubmit))
        text = ""
    }

    private func iconButton(_ systemName: String, _ labelKey: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .accessibility(label: Text(LocalizedStringKey(labelKey)))
    }
}

/// 全屏编辑框：iOS 13 无 TextEditor（14+），用 UITextView 包装；语音结果插光标处。
struct FullscreenTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.font = .systemFont(ofSize: 16)
        v.backgroundColor = .clear
        v.textColor = .white
        v.keyboardAppearance = .dark
        v.autocorrectionType = .no
        v.delegate = context.coordinator
        context.coordinator.parent = self
        context.coordinator.observeVoice(into: v)
        return v
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text, !context.coordinator.syncing {
            context.coordinator.syncing = true
            view.text = text
            context.coordinator.syncing = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FullscreenTextView?
        var syncing = false
        private var voiceObserver: NSObjectProtocol?

        func observeVoice(into textView: UITextView) {
            voiceObserver = NotificationCenter.default.addObserver(
                forName: .macscreenVoiceResult, object: nil, queue: .main) { [weak textView] note in
                guard let text = note.userInfo?["text"] as? String, let tv = textView else { return }
                tv.insertText(text)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let parent = parent else { return }
            syncing = true
            parent.text = textView.text
            syncing = false
        }

        deinit {
            if let o = voiceObserver { NotificationCenter.default.removeObserver(o) }
        }
    }
}

// MARK: - 窗口列表 sheet（对齐 Android showWindowsDialog）

struct WindowsSheet: View {
    let windows: [WindowInfoData]?
    var onPick: (WindowInfoData) -> Void
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            Group {
                if let list = windows, !list.isEmpty {
                    List(list) { win in
                        Button {
                            onPick(win)
                        } label: {
                            Text(win.displayTitle)
                                .lineLimit(2)
                                .foregroundColor(.primary)
                        }
                    }
                } else {
                    Text("windows_empty")
                        .foregroundColor(.secondary)
                }
            }
            .navigationBarTitle(Text("cd_windows"), displayMode: .inline)
            .navigationBarItems(trailing: Button(action: {
                presentation.wrappedValue.dismiss()
            }) { Text("cancel") })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - 语音录音覆盖层（大话筒呼吸动画 + 提示；点击结束）

struct VoiceOverlay: View {
    var voice: VoiceManager

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).edgesIgnoringSafeArea(.all)
            VStack(spacing: 14) {
                Image(systemName: "mic")
                    .font(.system(size: 64))
                    .foregroundColor(.white)
                    .modifier(Breathing())
                Text("voice_listening")
                    .font(.system(size: 20)).foregroundColor(.white)
                Text("voice_overlay_hint")
                    .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { voice.stop() }
    }
}

struct Breathing: ViewModifier {
    @State private var up = false
    func body(content: Content) -> some View {
        content
            .opacity(up ? 0.35 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    up = true
                }
            }
    }
}
