import SwiftUI
import AVFoundation

/// 扫码配对页：AVCaptureMetadataOutput 原生 QR 识别（iOS 13 可用，真机功能；
/// 模拟器无相机时显示错误文本）。识别到 macscreen:// 即回调。
struct QRScanView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScanController {
        let vc = QRScanController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: QRScanController, context: Context) {}
}

final class QRScanController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showUnsupported()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.showUnsupported()
                    return
                }
                self?.session.startRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    private func showUnsupported() {
        let label = UILabel()
        label.text = NSLocalizedString("err_camera_unavailable", comment: "")
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 32, dy: 0)
        view.addSubview(label)
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !handled else { return }
        if let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
           obj.type == .qr, let value = obj.stringValue,
           value.hasPrefix("macscreen://") {
            handled = true
            session.stopRunning()
            dismiss(animated: true) { [weak self] in
                self?.onCode?(value)
            }
        }
    }
}
