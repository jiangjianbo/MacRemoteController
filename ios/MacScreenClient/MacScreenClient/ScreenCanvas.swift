import SwiftUI
import UIKit

/// MJPEG 投屏画布：UIImageView 换帧 + 全套手势（对齐 Android VideoView + ScreenActivity）。
/// 缩放/平移是纯本地视觉变换；触点经 MouseMath 归一化后发 mouse 指令。
struct ScreenCanvas: UIViewRepresentable {
    @ObservedObject var session: SessionModel

    func makeUIView(context: Context) -> CanvasUIView {
        let view = CanvasUIView()
        view.onMouse = { action, nx, ny in
            session.send(Requests.mouse(action: action, nx: nx, ny: ny))
        }
        view.onZoomChanged = { session.applyZoomState($0) }
        session.frameSink = { jpeg in
            context.coordinator.decodeFrame(jpeg, into: view)
        }
        return view
    }

    func updateUIView(_ view: CanvasUIView, context: Context) {}

    func dismantleUIView(_ view: CanvasUIView, coordinator: Coordinator) {
        SessionModel.shared.frameSink = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// JPEG 解码在回调线程做，主线程只换 image（对齐 Android BitmapFactory 在读线程解码）
        func decodeFrame(_ jpeg: Data, into view: CanvasUIView) {
            guard let image = UIImage(data: jpeg) else { return }
            DispatchQueue.main.async { view.applyFrame(image) }
        }
    }
}

final class CanvasUIView: UIView {
    private let imageView = UIImageView()
    /// 最近帧像素尺寸（映射基准）
    private var imageSize: CGSize?

    // 缩放平移状态（与 Android VideoView 相同语义：pan 相对居中位置）
    private var zoom: Double = 1
    private var panX: Double = 0
    private var panY: Double = 0

    var onMouse: ((String, Double, Double) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?
    private let classifier = GestureClassifier()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageView.contentMode = .scaleToFill   // frame 由自算公式控制（不用 contentMode 缩放）
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(onSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        addGestureRecognizer(pinch)

        // 工具栏 ↺（Representable 与 SwiftUI 解耦：经通知转发）
        NotificationCenter.default.addObserver(forName: .macscreenResetZoom, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.resetView()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: 帧

    func applyFrame(_ image: UIImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.image = image
        imageSize = image.size
        layoutImage()
        CATransaction.commit()
    }

    private var isZoomed: Bool { zoom > 1.01 }

    /// 绘制公式与 MouseMath 一致：drawSize = imgSize*fit*zoom，offset = (view-drawSize)/2 + pan
    private func layoutImage() {
        guard let img = imageSize, bounds.width > 0, bounds.height > 0 else {
            imageView.frame = .zero
            return
        }
        let fit = min(bounds.width / img.width, bounds.height / img.height)
        let drawW = img.width * fit * zoom
        let drawH = img.height * fit * zoom
        imageView.frame = CGRect(x: (bounds.width - drawW) / 2 + panX,
                                 y: (bounds.height - drawH) / 2 + panY,
                                 width: drawW, height: drawH)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutImage()
    }

    // MARK: 映射

    private func map(_ point: CGPoint, coerce: Bool) -> (nx: Double, ny: Double)? {
        guard let img = imageSize else { return nil }
        return MouseMath.normalizedZoomed(viewW: bounds.width, viewH: bounds.height,
                                          imgW: img.width, imgH: img.height,
                                          zoom: zoom, panX: panX, panY: panY,
                                          x: point.x, y: point.y, coerceToBounds: coerce)
    }

    private func emit(_ action: String, at point: CGPoint, coerce: Bool = false) {
        guard let m = map(point, coerce: coerce) else { return }
        onMouse?(action, m.nx, m.ny)
    }

    // MARK: 手势

    @objc private func onSingleTap(_ g: UITapGestureRecognizer) {
        emit("click", at: g.location(in: self))
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        emit("double", at: g.location(in: self))
    }

    @objc private func onLongPress(_ g: UITapGestureRecognizer) {
        if g.state == .began {
            emit("right", at: g.location(in: self))
        }
    }

    /// 单指拖动：未缩放 → 鼠标 down/drag/up 序列；缩放态 → 本地平移。
    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        let time = Double(Date().timeIntervalSince1970 * 1000)
        switch g.state {
        case .began:
            classifier.onDown(x: p.x, y: p.y, timeMs: time)
        case .changed:
            if isZoomed {
                let t = g.translation(in: self)
                g.setTranslation(.zero, in: self)
                panX = MouseMath.clampPan(viewSize: bounds.width,
                                          fitDrawSize: fitDrawWidth(), zoom: zoom,
                                          pan: panX + t.x.doubleValue)
                panY = MouseMath.clampPan(viewSize: bounds.height,
                                          fitDrawSize: fitDrawHeight(), zoom: zoom,
                                          pan: panY + t.y.doubleValue)
                layoutImage()
            } else {
                if classifier.onMove(x: p.x, y: p.y, timeMs: time) {
                    emit("down", at: p, coerce: true)   // 拖动首帧：按下（coerce 防黑边卡键）
                } else if classifier.dragging {
                    emit("drag", at: p, coerce: true)
                }
            }
        case .ended, .cancelled:
            if !isZoomed {
                let result = classifier.onUp(x: p.x, y: p.y, timeMs: time)
                if result == .dragEnd {
                    emit("up", at: p, coerce: true)
                }
                // click/double 已由 tap recognizer 处理，忽略重复
            }
        default:
            break
        }
    }

    /// 双指捏合缩放（焦点锚定，纯本地）；接管中取消可能进行中的鼠标拖动。
    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            if classifier.dragging { emit("up", at: g.location(in: self), coerce: true) }
            classifier.cancel()
        case .changed:
            let focus = g.location(in: self)
            let target = (zoom * g.scale.doubleValue).clamped(1.0, 5.0)
            g.scale = 1
            guard let img = imageSize, target != zoom else { return }
            let fitW = fitDrawWidth(), fitH = fitDrawHeight()
            // 当前焦点对应的图像坐标（逆映射绘制公式）
            let vw = bounds.width.doubleValue, vh = bounds.height.doubleValue
            let imgW = Double(img.width), imgH = Double(img.height)
            let imgX = (focus.x.doubleValue - (vw - fitW * zoom) / 2 - panX) * imgW / (fitW * zoom)
            let imgY = (focus.y.doubleValue - (vh - fitH * zoom) / 2 - panY) * imgH / (fitH * zoom)
            zoom = target
            panX = MouseMath.anchoredPan(viewSize: vw, imgSize: imgW,
                                         fitDrawSize: fitW, zoom: zoom,
                                         focus: focus.x.doubleValue, imgCoord: imgX)
            panY = MouseMath.anchoredPan(viewSize: vh, imgSize: imgH,
                                         fitDrawSize: fitH, zoom: zoom,
                                         focus: focus.y.doubleValue, imgCoord: imgY)
            layoutImage()
            onZoomChanged?(isZoomed)
        default:
            break
        }
    }

    /// 还原缩放（工具栏 ↺）。
    func resetView() {
        zoom = 1
        panX = 0
        panY = 0
        layoutImage()
        onZoomChanged?(false)
    }

    private func fitDrawWidth() -> Double {
        guard let img = imageSize, bounds.width > 0 else { return bounds.width.doubleValue }
        return img.width * min(bounds.width / img.width, bounds.height / img.height)
    }

    private func fitDrawHeight() -> Double {
        guard let img = imageSize, bounds.width > 0 else { return bounds.height.doubleValue }
        return img.height * min(bounds.width / img.width, bounds.height / img.height)
    }
}

private extension CGFloat {
    var doubleValue: Double { Double(self) }
}

