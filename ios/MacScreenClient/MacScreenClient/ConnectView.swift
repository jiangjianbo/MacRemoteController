import SwiftUI

/// 连接页（对齐 Android MainActivity）：Bonjour 发现列表 + 手动表单 + 扫码配对 + 设置。
struct ConnectView: View {
    @EnvironmentObject var session: SessionModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var discovery = DiscoveryBrowser()
    @State private var showQR = false
    @State private var qrMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("section_discovered")) {
                    if let err = discovery.error {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    let resolved = discovery.services.filter { !$0.host.isEmpty }
                    if resolved.isEmpty {
                        Text("discovering").font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(resolved) { svc in
                        Button {
                            settings.host = svc.host
                            settings.port = svc.port
                            session.connect(host: svc.host, port: svc.port, token: settings.token)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(svc.name).foregroundColor(.primary)
                                    Text("\(svc.host):\(svc.port)")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if settings.token.isEmpty {
                                    Text("need_token").font(.system(size: 11)).foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("section_manual")) {
                    TextField("field_host", text: $settings.host)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("field_port", text: Binding(
                        get: { String(settings.port) },
                        set: { settings.port = Int($0) ?? 9700 }))
                        .keyboardType(.numberPad)
                    SecureField("field_token", text: $settings.token)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("pair_qr") { showQR = true }
                    Button("connect") {
                        session.connect()
                    }
                    .disabled(settings.host.isEmpty || settings.token.isEmpty || session.connecting)
                }

                Section(header: Text("status_line")) {
                    Text(session.connecting ? NSLocalizedString("connecting", comment: "")
                                            : session.statusLine.isEmpty
                        ? NSLocalizedString("status_idle", comment: "") : session.statusLine)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    NavigationLink(destination: SettingsView()) {
                        Text("nav_settings")
                    }
                }
            }
            .navigationBarTitle(Text("app_name"), displayMode: .inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $showQR, onDismiss: { qrMessage = nil }) {
            QRScanView(onCode: handleQR)
        }
        .toast(message: $qrMessage)
    }

    /// 扫码结果：解析 macscreen://connect 存设置并直连（对齐 Android QR 结果路径）。
    private func handleQR(_ content: String) {
        guard let info = PairingUri.parse(content) else {
            qrMessage = NSLocalizedString("err_bad_qr", comment: "")
            return
        }
        settings.host = info.host
        settings.port = info.port
        settings.token = info.token
        session.connect(host: info.host, port: info.port, token: info.token)
    }
}
