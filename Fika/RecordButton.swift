import KDCircularProgress
import UIKit

protocol RecordButtonDelegate: class {
    func audioLevel(for recordButton: RecordButton) -> Float
    func recordButton(_ recordButton: RecordButton, requestingState recording: Bool)
    /// If the user is moving their finger up while long pressing, this will be called
    /// on the delegate. The value will be in the range 0.0-1.0 where 0.0 means no
    /// additional zoom and 1.0 means maximum possible zoom.
    func recordButton(_ recordButton: RecordButton, requestingZoom magnitude: Float)
}

class RecordButton: UIButton {
    weak var delegate: RecordButtonDelegate?
    private(set) var isLongPressing = false

    override var frame: CGRect {
        didSet {
            self.layer.cornerRadius = self.frame.width / 2
        }
    }

    var isRecording = false {
        didSet {
            guard self.isRecording != oldValue else {
                return
            }
            if self.isRecording {
                let isPremium = BackendClient.instance.session?.isPremium ?? false
                self.handleBeginRecording(timeLimit: isPremium ? nil : 60)
            } else {
                self.handleEndRecording()
            }
        }
    }

    override init(frame: CGRect) {
        let viz = UIView(frame: frame.insetBy(dx: -5, dy: -5))
        viz.borderColor = UIColor.white.withAlphaComponent(0.5)
        viz.layer.borderWidth = 0.5
        viz.layer.cornerRadius = viz.bounds.width / 2
        viz.isHidden = true
        self.visualizer = viz

        let progress = KDCircularProgress(frame: frame.insetBy(dx: -10, dy: -10), colors: .white)
        progress.progressThickness = 0.2
        progress.trackThickness = 0.2
        progress.clockwise = true
        progress.roundedCorners = true
        progress.trackColor = UIColor.white
        progress.startAngle = -90
        progress.glowMode = .noGlow
        self.progressView = progress

        super.init(frame: frame)

        self.visualizerDisplayLink = CADisplayLink(target: self, selector: #selector(RecordButton.updateVisualizer))
        self.visualizerDisplayLink.isPaused = true
        self.visualizerDisplayLink.add(to: .main, forMode: .defaultRunLoopMode)

        self.layoutIfNeeded()
        self.addSubview(progress)
        //self.insertSubview(viz, at: 0)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else {
            return
        }
        self.lastZoom = 0
        self.touchPoint = touch.preciseLocation(in: self.window!)
        self.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        if !self.isRecording {
            self.delegate?.recordButton(self, requestingState: true)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        self.feedbackTimer?.invalidate()
        self.isLongPressing = false
        self.delegate?.recordButton(self, requestingState: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        self.isLongPressing = false
        // Regardless of whether the recording will successfully stop, restore the button size.
        UIView.animate(withDuration: 0.2) {
            self.transform = .identity
        }
        if let timer = self.feedbackTimer, timer.isValid {
            // The touch was too short to be long pressing, which means recording was just toggled on.
            timer.invalidate()
            return
        } else if self.isRecording {
            // Either this was a second tap, or the button was long pressed.
            self.delegate?.recordButton(self, requestingState: false)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard self.isLongPressing, let from = self.touchPoint, let touch = touches.first else {
            return
        }
        let y = touch.preciseLocation(in: self.window!).y
        let magnitude = min(1, max(0, (from.y - (y + 50)) / from.y * 1.3))
        guard magnitude != self.lastZoom else {
            return
        }
        self.delegate?.recordButton(self, requestingZoom: Float(magnitude))
        self.lastZoom = magnitude
    }

    // MARK: - Private

    private let progressView: KDCircularProgress
    private let visualizer: UIView

    private var feedbackTimer: Timer?
    private var lastZoom = CGFloat(0)
    private var limitTimer: Timer?
    private var touchPoint: CGPoint?
    private var visualizerDisplayLink: CADisplayLink!
    private var visualizerScale = CGFloat(0)

    private func handleBeginRecording(timeLimit: TimeInterval?) {
        self.visualizerDisplayLink.isPaused = false
        self.visualizer.isHidden = false
        // Enable long pressing mode after a short period of time. Note that isRecording
        // must have been set to true within that time for this to do anything.
        self.feedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            guard self.isRecording else {
                return
            }
            self.isLongPressing = true
            UIView.animate(withDuration: 0.3) {
                self.transform = CGAffineTransform(scaleX: 1.45, y: 1.45)
            }
        }

        self.progressView.trackColor = UIColor.white.withAlphaComponent(0.4)

        if let timeLimit = timeLimit {
            self.progressView.animate(toAngle: 360, duration: timeLimit, completion: nil)
            self.limitTimer = Timer.scheduledTimer(withTimeInterval: timeLimit, repeats: false) { _ in
                guard self.isRecording else {
                    return
                }
                self.delegate?.recordButton(self, requestingState: false)
            }
        }
    }

    private func handleEndRecording() {
        self.limitTimer?.invalidate()
        self.limitTimer = nil
        self.visualizerDisplayLink.isPaused = true
        self.visualizer.isHidden = true
        UIView.animate(withDuration: 0.2) {
            self.backgroundColor = .clear
            self.progressView.trackColor = UIColor.white
        }
        self.progressView.stopAnimation()
    }

    private dynamic func updateVisualizer() {
        guard let delegate = self.delegate else {
            return
        }
        let scale = CGFloat(delegate.audioLevel(for: self))
        self.visualizerScale = scale < self.visualizerScale ? (self.visualizerScale * 8 + scale) / 9 : scale
        self.visualizer.backgroundColor = UIColor.white.withAlphaComponent(scale / 8)
        self.visualizer.transform = CGAffineTransform(scaleX: self.visualizerScale, y: self.visualizerScale)
        let alpha = max(0, pow(self.visualizerScale - 1, 1.3))
        self.backgroundColor = UIColor.fikaRed.withAlphaComponent(alpha)
    }
}
