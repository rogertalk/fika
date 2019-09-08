import AVFoundation
import pop
import UIKit

class CameraView: Component {
    var isMinimized: Bool {
        return self.frame.size == self.minSize
    }

    init(frame: CGRect, preview: AVCaptureVideoPreviewLayer) {
        self.video = DrawableVideo(scale: UIScreen.main.nativeScale)
        super.init(frame: frame, drawable: self.video)

        self.layoutPreview()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        self.video.appendVideo(buffer)
    }

    func focusPoint(for point: CGPoint) -> CGPoint {
        return Recorder.instance.previewLayer.captureDevicePointOfInterest(for: point)
    }

    func layoutPreview() {
        Recorder.instance.previewLayer.frame = self.bounds
        self.layer.addSublayer(Recorder.instance.previewLayer)
    }

    func minimize(animated: Bool = true) {
        self.set(shadowX: 0, y: 1, radius: 3, color: .black, opacity: 0.4)
        self.set(
            frame: CGRect(origin: CGPoint(x: UIScreen.main.bounds.width - 76, y: 4), size: self.minSize),
            cornerRadius: 4,
            animated: animated)
    }

    func maximize(animated: Bool = true) {
        self.unsetShadow()
        self.set(frame: UIScreen.main.bounds, animated: animated)
    }

    func set(frame: CGRect, cornerRadius: CGFloat = 0, animated: Bool = true) {
        let preview = Recorder.instance.previewLayer
        preview.cornerRadius = cornerRadius
        self.layer.cornerRadius = cornerRadius

        if animated {
            let selfAnim = POPBasicAnimation(propertyNamed: kPOPViewFrame)!
            selfAnim.duration = 0.2
            selfAnim.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
            selfAnim.fromValue = self.frame
            selfAnim.toValue = frame
            self.pop_add(selfAnim, forKey: "frame")

            preview.anchorPoint = .zero

            let prevAnim = POPBasicAnimation(propertyNamed: kPOPViewBounds)!
            prevAnim.duration = 0.2
            prevAnim.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
            prevAnim.fromValue = preview.bounds
            prevAnim.toValue = CGRect(origin: .zero, size: frame.size)
            preview.pop_add(prevAnim, forKey: "bounds")
        } else {
            self.frame = frame
            preview.anchorPoint = .zero
            preview.bounds = self.bounds
        }
    }

    override func layoutSubviews() {
        Recorder.instance.previewLayer.frame = self.bounds
    }

    // MARK: - Private

    private let minSize = CGSize(width: 72, height: 112)
    private let video: DrawableVideo
}
