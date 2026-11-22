import Foundation
import AppKit
import MacScreenCore

// MARK: - 菜单栏控制器（UI 模式：菜单栏常驻，无 Dock 图标）

public final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let runtime: AgentRuntime
    var statusItem: NSStatusItem?
    var qrWindow: NSWindow?
    var shareWindow: NSWindow?
    var captureToggleItem: NSMenuItem?
    var loginToggleItem: NSMenuItem?
    var statusLineItem: NSMenuItem?

    public init(runtime: AgentRuntime) {
        self.runtime = runtime
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 菜单栏应用：后台常驻
        runtime.start()
        buildMenu()
        Log.i("UI 模式启动完成")
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: 菜单

    func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🖥"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "LAN-Mac-Controller 投屏服务", action: nil, keyEquivalent: "")
        let statusLine = NSMenuItem(title: "状态：运行中", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        statusLineItem = statusLine
        menu.addItem(.separator())

        menu.addItem(self.menuItem("配对二维码…", action: #selector(showQRWindow)))
        menu.addItem(self.menuItem("手机扫码下载 APK…", action: #selector(showDownloadQR)))
        captureToggleItem = menuItem(captureToggleTitle(), action: #selector(toggleCapture))
        menu.addItem(captureToggleItem!)
        loginToggleItem = menuItem(loginToggleTitle(), action: #selector(toggleLoginItem))
        menu.addItem(loginToggleItem!)
        menu.addItem(.separator())
        menu.addItem(menuItem("打开日志目录", action: #selector(openLogs)))
        menu.addItem(menuItem("退出", action: #selector(quit)))
        item.menu = menu
        statusItem = item
    }

    func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        statusLineItem?.title = "状态：运行中，已连接 \(runtime.registry.count()) 台设备"
        captureToggleItem?.title = captureToggleTitle()
        loginToggleItem?.title = loginToggleTitle()
    }

    func captureToggleTitle() -> String {
        runtime.settings.captureEnabled ? "暂停投屏" : "继续投屏"
    }

    func loginToggleTitle() -> String {
        runtime.loginItem.isEnabled() ? "关闭开机启动" : "开机自动启动"
    }

    // MARK: 动作

    @objc func toggleCapture() {
        runtime.settings.captureEnabled.toggle()
        if runtime.settings.captureEnabled {
            runtime.capture.startIfNeeded()
        } else {
            runtime.capture.stop()
        }
    }

    @objc func toggleLoginItem() {
        do {
            if runtime.loginItem.isEnabled() {
                runtime.loginItem.disable()
                runtime.settings.loginItemEnabled = false
            } else {
                try runtime.loginItem.enable()
                runtime.settings.loginItemEnabled = true
            }
        } catch {
            Log.e("开机启动设置失败：\(error)")
        }
    }

    @objc func openLogs() {
        let dir = runtime.config.logFile.map { ($0 as NSString).deletingLastPathComponent }
            ?? "~/Library/Logs"
        NSWorkspace.shared.open(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
    }

    @objc func quit() {
        runtime.stop()
        NSApp.terminate(nil)
    }

    // MARK: 配对二维码窗口

    @objc func showQRWindow() {
        let info = runtime.connectionInfo()
        guard let qrCG = QRCodeService.qrImage(content: info.qrContent, sizePx: 320) else {
            Log.e("二维码生成失败")
            return
        }
        let window = qrWindow ?? makeQRWindow()
        qrWindow = window

        let imageView = window.contentView?.subviews.compactMap { $0 as? NSImageView }.first
        let textField = window.contentView?.subviews.compactMap { $0 as? NSTextField }.first
        imageView?.image = NSImage(cgImage: qrCG, size: NSSize(width: 320, height: 320))
        textField?.stringValue = """
        用手机 App 扫码配对，或手动输入：
        地址 \(info.host):\(info.port)  令牌 \(info.token)
        """
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeQRWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "LAN-Mac-Controller 配对"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 460))

        let imageView = NSImageView(frame: NSRect(x: 30, y: 120, width: 320, height: 320))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(wrappingLabelWithString: "")
        label.frame = NSRect(x: 20, y: 16, width: 340, height: 96)
        label.alignment = .center
        label.isEditable = false
        container.addSubview(imageView)
        container.addSubview(label)
        window.contentView = container
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: 手机扫码下载（HTTP 文件分享）

    @objc func showDownloadQR() {
        // 未设置文件时先尝试默认构建产物 APK；找不到则打开空状态窗口，由用户手动选文件
        if runtime.fileShare?.currentFile == nil {
            runtime.resolveAndSetDefaultShareFile()
        }
        showShareWindow()
    }

    @objc func chooseShareFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择要分享给手机的文件（任意类型，手机扫码后浏览器下载）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard runtime.setShareFile(url) != nil else {
            let alert = NSAlert()
            alert.messageText = "无法分享该文件"
            alert.informativeText = "文件不可读或不存在：\(url.path)"
            alert.runModal()
            return
        }
        showShareWindow()
    }

    private func showShareWindow() {
        let window = shareWindow ?? makeShareWindow()
        shareWindow = window
        let imageView = window.contentView?.subviews.compactMap { $0 as? NSImageView }.first
        let textField = window.contentView?.subviews.compactMap { $0 as? NSTextField }.first
        if let shareURL = runtime.shareURLString,
           let file = runtime.fileShare?.currentFile {
            let sizeText = ByteCountFormatter.string(
                fromByteCount: Int64(runtime.fileShare?.currentFileSize ?? 0), countStyle: .file)
            if let qrCG = QRCodeService.qrImage(content: shareURL, sizePx: 320) {
                imageView?.image = NSImage(cgImage: qrCG, size: NSSize(width: 320, height: 320))
            } else {
                Log.e("二维码生成失败")
            }
            textField?.stringValue = """
            \(file.lastPathComponent)（\(sizeText)）
            手机扫码后浏览器将开始下载：
            \(shareURL)
            注意：同网段设备均可下载该文件。
            """
        } else {
            imageView?.image = nil
            textField?.stringValue = """
            尚未选择要分享的文件。
            点下方「选择文件…」选择任意文件（如构建好的 APK），
            选择后这里会显示下载二维码。
            """
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeShareWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "手机下载"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 560))
        let imageView = NSImageView(frame: NSRect(x: 30, y: 210, width: 320, height: 320))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(wrappingLabelWithString: "")
        label.frame = NSRect(x: 20, y: 76, width: 340, height: 126)
        label.alignment = .center
        label.isEditable = false
        let chooseButton = NSButton(title: "选择文件…", target: self, action: #selector(chooseShareFile))
        chooseButton.bezelStyle = .rounded
        chooseButton.frame = NSRect(x: 115, y: 24, width: 150, height: 36)
        container.addSubview(imageView)
        container.addSubview(label)
        container.addSubview(chooseButton)
        window.contentView = container
        window.isReleasedWhenClosed = false
        return window
    }
}

// MARK: - 入口

let config = LaunchConfig.parse(CommandLine.arguments)

if let logFile = config.logFile {
    Log.shared.setup(file: logFile)
}

if config.daemon {
    // 后台模式：无 UI，信号优雅退出
    let runtime = AgentRuntime(config: config)
    runtime.start()

    let signalQueue = DispatchQueue(label: "macscreen.signals")
    // 必须真正持有 source：释放后信号处置退回 SIG_IGN，进程将永久忽略 SIGTERM/SIGINT
    var signalSources: [DispatchSourceSignal] = []
    for name in [SIGINT, SIGTERM] {
        signal(name, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: name, queue: signalQueue)
        source.setEventHandler {
            Log.i("收到信号 \(name)，退出")
            // 看门狗：stop() 万一卡住也保证退出
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
            runtime.stop()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let controller = MenuBarController(runtime: AgentRuntime(config: config))
    app.delegate = controller
    app.run()
}
