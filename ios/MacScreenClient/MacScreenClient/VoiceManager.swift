import Foundation
import AVFoundation
import Speech

/// 语音输入管理：local（SFSpeechRecognizer，语言跟随系统）+ cloud（AVAudioRecorder 录
/// 16k/16bit/mono WAV 上传转写）。结果永远插入文本光标位置（由 UI 层执行）。
final class VoiceManager: ObservableObject {
    enum Engine { case local, cloud }

    private(set) var engine: Engine = .local
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recorder: AVAudioRecorder?
    private var recordStartAt: Date?
    private var timeoutWork: DispatchWorkItem?

    /// UI 状态经 SessionModel.recording 发布
    private weak var session: SessionModel?
    private var settings: AppSettings?

    /// 切换启停（工具栏按钮/长按入口）。<400ms 视为误触忽略（对齐 Android）。
    func toggle(session: SessionModel, settings: AppSettings) {
        if session.recording {
            stop()
        } else {
            start(session: session, settings: settings)
        }
    }

    func start(session: SessionModel, settings: AppSettings) {
        guard !session.recording else { return }
        self.session = session
        self.settings = settings
        engine = settings.voiceEngine == "cloud" ? .cloud : .local

        let askMic: (Bool) -> Void = { [weak self] micGranted in
            guard micGranted else {
                session.toast = NSLocalizedString("err_no_mic_permission", comment: "")
                return
            }
            self?.beginRecording()
        }

        if engine == .local {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard status == .authorized else {
                        session.toast = NSLocalizedString("err_no_speech_permission", comment: "")
                        return
                    }
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        DispatchQueue.main.async { askMic(granted) }
                    }
                }
            }
        } else {
            if (settings.cloudUrl.trimmingCharacters(in: .whitespaces)).isEmpty {
                session.toast = NSLocalizedString("err_cloud_url_empty", comment: "")
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { askMic(granted) }
            }
        }
    }

    private func beginRecording() {
        guard let session = session else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true)
        } catch {
            session.toast = error.localizedDescription
            return
        }
        session.recording = true
        recordStartAt = Date()
        switch engine {
        case .local: startLocal()
        case .cloud: startCloud()
        }
        // 录音上限：cloud 60s / local 8s 兜底（厂商 ROM 不回调）（对齐 Android）
        let limit: TimeInterval = engine == .cloud ? 60 : 8
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
    }

    // MARK: local（SFSpeechRecognizer）

    private func startLocal() {
        let audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        // 不强制 requiresOnDeviceRecognition——尽量兼容（模拟器/无本地方言包时回退服务端识别）
        let locale = Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
        let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer = recognizer, recognizer.isAvailable else {
            stopWithToast(NSLocalizedString("err_speech_unavailable", comment: ""))
            return
        }
        self.audioEngine = audioEngine
        recognitionRequest = request
        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
            buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stopWithToast(error.localizedDescription)
            return
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self?.deliver(text) }
            }
        }
    }

    // MARK: cloud（AVAudioRecorder → WAV → HTTP）

    private func startCloud() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macscreen-voice.wav")
        let settingsDict: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settingsDict) else {
            stopWithToast("AVAudioRecorder init failed")
            return
        }
        self.recorder = recorder
        recorder.record()
    }

    // MARK: 停止与结果

    func stop() {
        guard let session = session, session.recording else { return }
        timeoutWork?.cancel()
        if let started = recordStartAt, Date().timeIntervalSince(started) < 0.4 {
            teardownAudio()
            session.recording = false
            return   // 误触（对齐 Android <400ms）
        }
        switch engine {
        case .local:
            recognitionRequest?.endAudio()
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            // 结果异步回 deliver；local 模式超时兜底已由 8s 定时覆盖
            session.recording = false
            teardownAudio()
        case .cloud:
            recorder?.stop()
            session.recording = false
            teardownAudio()
            transcribeCloud()
        }
    }

    private func transcribeCloud() {
        guard let settings = settings, let session = session,
              let recorder = recorder else { return }
        let wav: Data
        do {
            wav = try Data(contentsOf: recorder.url)
        } catch {
            session.toast = error.localizedDescription
            return
        }
        CloudPoster.transcribe(config: settings.cloudConfig, wav: wav) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text): self?.deliver(text)
                case .failure(let error): self?.stopWithToast(error.localizedDescription)
                }
            }
        }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty, let session = session else { return }
        NotificationCenter.default.post(name: .macscreenVoiceResult,
                                        object: nil, userInfo: ["text": text])
        teardownAudio()
        _ = session
    }

    private func stopWithToast(_ message: String) {
        teardownAudio()
        session?.recording = false
        session?.toast = message
    }

    private func teardownAudio() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        recorder = nil
        recordStartAt = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension Notification.Name {
    /// 语音识别结果（UI 层在光标处插入）
    static let macscreenVoiceResult = Notification.Name("macscreen.voiceResult")
}
