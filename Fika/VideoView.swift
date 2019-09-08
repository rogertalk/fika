import AVFoundation
import UIKit

class VideoView: Component, UIGestureRecognizerDelegate {
    override var frame: CGRect {
        get { return super.frame }
        set {
            super.frame = newValue
            self.playerLayer.frame = self.bounds
        }
    }

    private var muted = false
    private(set) var playerOffset = CFTimeInterval(0)

    init(frame: CGRect) {
        // Create the preview layer for display while recording.
        self.playerLayer = AVPlayerLayer(player: self.player)
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill
        self.playerLayer.anchorPoint = .zero
        self.playerLayer.backgroundColor = UIColor.black.cgColor
        self.playerLayer.masksToBounds = true

        // Set up the renderer which will render the video to the recorded file.
        self.video = DrawableVideo(scale: UIScreen.main.nativeScale)

        super.init(frame: frame, drawable: self.video)

        self.timeObserver = self.player.addPeriodicTimeObserver(forInterval: CMTimeMake(1, 30), queue: DispatchQueue.main) {
            [unowned self] time -> Void in
            self.playerOffset = CMTimeGetSeconds(time)
        }

        self.link = CADisplayLink(target: self, selector: #selector(VideoView.renderFrame))
        self.link.isPaused = true
        self.link.add(to: .current, forMode: .commonModes)

        self.playerLayer.frame = self.bounds
        self.layer.addSublayer(self.playerLayer)

        self.toggleLoudspeakerButton.addTarget(self, action: #selector(VideoView.toggleLoudspeaker), for: .touchUpInside)
        self.toggleLoudspeakerButton.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        self.toggleLoudspeakerButton.layer.cornerRadius = 20
        self.toggleLoudspeakerButton.setTitleColor(.white, for: .normal)
        self.toggleLoudspeakerButton.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .highlighted)
        self.toggleLoudspeakerButton.titleLabel!.font = UIFont.materialFont(ofSize: 24)
        self.toggleLoudspeakerButton.frame = CGRect(x: frame.maxX - 50, y: 10, width: 40, height: 40)
        self.toggleLoudspeakerButton.backgroundColor = UIColor(white: 0, alpha: 0.3)
        self.addSubview(self.toggleLoudspeakerButton)
        self.updateLoudspeakerSetting()

        VolumeMonitor.instance.routeChange.addListener(self, method: VideoView.updateLoudspeakerSetting)

        self.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(VideoView.handlePan)))
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(VideoView.togglePlayback)))
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = self.timeObserver {
            self.player.removeTimeObserver(observer)
            self.timeObserver = nil
        }
        self.link.invalidate()
    }

    func clearVideo() {
        if let output = self.output {
            if let oldItem = self.player.currentItem {
                oldItem.remove(output)
            }
            self.output = nil
        }
        self.link.isPaused = true
        self.player.pause()
        self.player.cancelPendingPrerolls()
        self.player.replaceCurrentItem(with: nil)
        self.currentURL = nil
    }

    func loadVideo(url: URL) {
        // TODO: Display loader while loading video track.
        if url == self.currentURL {
            NSLog("WARNING: Ignoring second load of identical video URL")
            return
        }

        self.clearVideo()
        self.currentURL = url

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: Int32(kCVPixelFormatType_32BGRA)),
            ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        self.output = output

        let item = AVPlayerItem(url: url)
        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError?
            guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded else {
                NSLog("%@", "WARNING: Failed to load video (\(String(describing: error)))")
                return
            }
            // Start showing the video and capture its output.
            DispatchQueue.main.async {
                item.add(output)
                self.player.replaceCurrentItem(with: item)
                output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
                if self.player.rate == 0 {
                    self.togglePlayback()
                }
            }
            guard let track = asset.tracks(withMediaType: AVMediaTypeVideo).first else {
                // TODO: This happens for streams, what to do?
                return
            }
            track.loadValuesAsynchronously(forKeys: ["preferredTransform"]) {
                guard track.statusOfValue(forKey: "preferredTransform", error: &error) == .loaded else {
                    NSLog("%@", "WARNING: Failed to get preferred transform (\(String(describing: error)))")
                    return
                }
                // TODO: Respect preferredTransform.
            }
        }
    }

    func pause() {
        self.link.isPaused = true
        self.player.pause()
    }

    func play() {
        if let item = self.player.currentItem, abs(item.duration.seconds - self.playerOffset) < 0.1 {
            self.seek(to: 0)
        }
        self.link.isPaused = false
        if !self.muted && AudioService.instance.usingInternalSpeaker {
            AudioService.instance.useLoudspeaker = true
        }
        self.player.play()
    }

    func seek(to offset: CFTimeInterval) {
        let time = CMTime(seconds: offset, preferredTimescale: 1000)
        self.player.seek(to: time)
    }

    // MARK: - UIGestureRecognizerDelegate

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        let velocity = pan.velocity(in: nil)
        return abs(velocity.x) > abs(velocity.y)
    }

    // MARK: - Private

    private let player = AVPlayer()
    private let playerLayer: AVPlayerLayer
    private let toggleLoudspeakerButton = UIButton(type: .custom)
    private let video: DrawableVideo

    private var link: CADisplayLink!
    private var currentURL: URL?
    private var output: AVPlayerItemVideoOutput?
    private var timeObserver: Any?
    private var wasPlaying = false

    private dynamic func handlePan(recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            self.wasPlaying = self.player.rate != 0
            self.player.pause()
        case .changed:
            self.playerOffset += CFTimeInterval(recognizer.translation(in: nil).x / 10)
            self.seek(to: self.playerOffset)
            recognizer.setTranslation(.zero, in: nil)
        default:
            if self.wasPlaying {
                self.player.play()
            }
        }
    }

    private dynamic func renderFrame() {
        guard let output = self.output else {
            return
        }
        let nextVSync = (self.link.timestamp + self.link.duration)
        let outputItemTime = output.itemTime(forHostTime: nextVSync)
        guard output.hasNewPixelBuffer(forItemTime: outputItemTime) else {
            return
        }
        guard let buffer = output.copyPixelBuffer(forItemTime: outputItemTime, itemTimeForDisplay: nil) else {
            return
        }
        self.video.appendVideo(buffer)
    }

    private dynamic func toggleLoudspeaker() {
        guard AudioService.instance.usingInternalSpeaker else {
            // Leave headphones etc alone.
            return
        }
        self.muted = !self.muted
        if !self.muted {
            AudioService.instance.useLoudspeaker = true
        }
        self.updateLoudspeakerSetting()
    }

    private dynamic func togglePlayback() {
        let label = UILabel(frame: CGRect(origin: .zero, size: CGSize(width: 100, height: 100)))
        label.backgroundColor = UIColor(white: 0, alpha: 0.6)
        label.clipsToBounds = true
        label.layer.cornerRadius = label.frame.size.width / 2
        label.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        label.font = UIFont.materialFont(ofSize: 80)
        label.textAlignment = .center
        label.textColor = .white
        if self.player.rate != 0 {
            label.text = "pause"
            self.pause()
        } else {
            label.text = "play_arrow"
            self.play()
        }
        label.alpha = 1
        label.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        self.addSubview(label)
        UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseOut], animations: {
            label.alpha = 0
            label.transform = .identity
        }, completion: { _ in
            label.removeFromSuperview()
        })
    }

    private func updateLoudspeakerSetting(volume: Float = -1) {
        guard AudioService.instance.usingInternalSpeaker else {
            // Leave headphones etc alone.
            self.player.isMuted = false
            self.toggleLoudspeakerButton.setTitle("headset", for: .normal)
            return
        }
        if self.muted {
            self.player.isMuted = true
            self.toggleLoudspeakerButton.setTitle("volume_off", for: .normal)
        } else {
            self.player.isMuted = false
            self.toggleLoudspeakerButton.setTitle("volume_up", for: .normal)
        }
    }
}
