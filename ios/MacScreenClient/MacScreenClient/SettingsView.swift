import SwiftUI

/// 设置页（对齐 Android SettingsActivity）：语音引擎 local/cloud + 云端参数 + 回车开关。
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section(header: Text("section_voice_engine")) {
                Picker(selection: $settings.voiceEngine, label: Text("voice_engine")) {
                    Text("engine_local").tag("local")
                    Text("engine_cloud").tag("cloud")
                }
                .pickerStyle(SegmentedPickerStyle())

                if settings.voiceEngine == "cloud" {
                    TextField("cloud_url", text: $settings.cloudUrl)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("cloud_key", text: $settings.cloudKey)
                        .autocapitalization(.none)
                    TextField("cloud_model", text: $settings.cloudModel)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Picker(selection: $settings.cloudStyle, label: Text("cloud_style")) {
                        Text("style_openai").tag("openai")
                        Text("style_raw").tag("raw")
                    }
                }
                Text(settings.voiceEngine == "cloud"
                     ? "voice_cloud_desc" : "voice_local_desc")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle("voice_submit", isOn: $settings.voiceSubmit)
            }

            Section(header: Text("section_about")) {
                HStack {
                    Text("device_name")
                    Spacer()
                    Text(settings.deviceName).foregroundColor(.secondary)
                }
            }
        }
        .navigationBarTitle(Text("nav_settings"), displayMode: .inline)
    }
}
