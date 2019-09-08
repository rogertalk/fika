import AVFoundation
import UIKit

private func createLayer(player: AVPlayer, view: UIView) -> AVPlayerLayer {
    let layer = AVPlayerLayer(player: player)
    layer.frame = UIApplication.shared.keyWindow!.bounds
    layer.backgroundColor = UIColor.black.cgColor
    layer.videoGravity = AVLayerVideoGravityResizeAspect
    view.layer.insertSublayer(layer, at: 0)
    return layer
}

protocol SwappingQueuePlayerDelegate: class {
    func playerDidFinishPlayingChunk(_ player: SwappingQueuePlayer)
    func player(_ player: SwappingQueuePlayer, offsetDidChange offset: TimeInterval)
}

class SwappingQueuePlayer {
    weak var delegate: SwappingQueuePlayerDelegate?

    var isPaused: Bool {
        get {
            return self.player.rate == 0
        }
    }

    var duration: TimeInterval {
        return self.player.currentItem?.asset.duration.seconds ?? 0.0
    }

    var rate: Float = 1.0 {
        didSet {
            SettingsManager.playbackRate = self.rate
            if self.isPlaying {
                self.player.playImmediately(atRate: self.rate)
            }
        }
    }

    deinit {
        self.unregisterTimeObserver()
        self.layer1.player = nil
        self.layer1.removeFromSuperlayer()
        self.player1.replaceCurrentItem(with: nil)
        self.layer2.player = nil
        self.layer2.removeFromSuperlayer()
        self.player2.replaceCurrentItem(with: nil)
    }

    init(container: UIView) {
        self.view = container
        self.layer1 = createLayer(player: self.player1, view: container)
        self.layer2 = createLayer(player: self.player2, view: container)
        self.layer2.isHidden = true

        self.rate = SettingsManager.playbackRate
        self.audioLevelMeter = AudioLevelMeter()
    }

    func layout() {
        let rect = UIApplication.shared.keyWindow!.bounds
        self.layer1.frame = rect
        self.layer2.frame = rect
    }

    func play(url: URL, next: URL?, isRewind: Bool) {
        AudioService.instance.updateRoutes()

        // TODO: Remove rewind hack
        if self.isPlaying && !isRewind {
            self.player.pause()
            self.swap()
        } else {
            // TODO: Only use the Tap for audio files
            self.player.replaceCurrentItem(with: self.audioLevelMeter.getTappedPlayerItem(url: url))
            self.isPlaying = true
            self.layer2.isHidden = false
        }

        // Set up handler for reaching end of current item and play the provided URL.
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(SwappingQueuePlayer.playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: self.player.currentItem)
        self.player.playImmediately(atRate: self.rate)
        
        // Listen for progress of playback.
        self.unregisterTimeObserver()
        self.timeObserver = self.player.addPeriodicTimeObserver(forInterval: CMTimeMake(1, 30), queue: DispatchQueue.main) {
            [unowned self] time -> Void in
            let seconds = CMTimeGetSeconds(time)
            if seconds > 0.0 {
                self.delegate?.player(self, offsetDidChange: seconds)
            }
        }
        self.timeObserverPlayer = self.player

        // Preload the next URL (if any).
        if let next = next {
            // TODO: Only use the Tap for audio files
            self.nextPlayer.replaceCurrentItem(with: self.audioLevelMeter.getTappedPlayerItem(url: next))
            if self.nextPlayer.status == .readyToPlay {
                // TODO: Ensure we always call preroll?
                self.nextPlayer.preroll(atRate: self.rate)
            }
        } else {
            self.nextPlayer.replaceCurrentItem(with: nil)
        }
    }
    
    func pause() {
        guard self.isPlaying else {
            return
        }
        self.player.pause()
        self.isPlaying = false
    }

    func resume() {
        guard !self.isPlaying else {
            return
        }
        self.player.playImmediately(atRate: self.rate)
        self.isPlaying = true
    }

    func rewind(by seconds: Float) {
        let time = CMTime(seconds: Double(seconds), preferredTimescale: 1000)
        self.player.seek(to: max(kCMTimeZero, self.player.currentTime() - time))
    }

    func seek(to offset: Float) {
        self.player.seek(to: CMTime(seconds: self.duration * Double(offset), preferredTimescale: 1000))
    }

    // MARK: - Private properties

    private let layer1, layer2: AVPlayerLayer
    private let player1 = AVPlayer()
    private let player2 = AVPlayer()
    private let view: UIView

    private var isPlaying = false
    private var isSwapped = false
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    private var audioLevelMeter: AudioLevelMeter

    private var layer: AVPlayerLayer {
        return self.isSwapped ? self.layer2 : self.layer1
    }

    private var nextLayer: AVPlayerLayer {
        return self.isSwapped ? self.layer1 : self.layer2
    }

    private var nextPlayer: AVPlayer {
        return self.isSwapped ? self.player1 : self.player2
    }

    private var player: AVPlayer {
        return self.isSwapped ? self.player2 : self.player1
    }

    // MARK: - Private methods
    
    private func unregisterTimeObserver() {
        guard let observer = self.timeObserver, let player = self.timeObserverPlayer else {
            return
        }
        player.removeTimeObserver(observer)
        self.timeObserver = nil
        self.timeObserverPlayer = nil
    }

    @objc private func playerItemDidReachEnd(_ notification: NSNotification) {
        NotificationCenter.default.removeObserver(self)
        self.unregisterTimeObserver()
        self.delegate?.playerDidFinishPlayingChunk(self)
    }

    private func swap() {
        self.isSwapped = !self.isSwapped
        self.view.layer.insertSublayer(self.nextLayer, below: self.layer)
    }
}
