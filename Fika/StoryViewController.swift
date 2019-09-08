import Alamofire
import AVFoundation
import Crashlytics
import DateTools

class StoryViewController:
    UIViewController,
    SwappingQueuePlayerDelegate,
    ReviewDelegate,
    UITableViewDelegate,
    UITableViewDataSource {

    @IBOutlet weak var attachmentButton: UIButton!
    @IBOutlet weak var backgroundImageView: BlurredImageView!
    @IBOutlet weak var chunkTimestampLabel: UILabel!
    @IBOutlet weak var loudspeakerToggleButton: UIButton!
    @IBOutlet weak var playbackView: UIView!
    @IBOutlet weak var progressSlider: UISlider!
    @IBOutlet weak var senderNameLabel: UILabel!
    @IBOutlet weak var subtitlesLabel: UILabel!

    // TODO: Move this into its own xib/class.
    @IBOutlet weak var feedbackAttachmentView: UIView!
    @IBOutlet weak var feedbackView: UIView!
    @IBOutlet weak var feedbackTableView: UITableView!
    @IBOutlet weak var likeCountLabel: UILabel!
    @IBOutlet weak var dislikeCountLabel: UILabel!
    @IBOutlet weak var rewindLabel: UILabel!

    var autoplay = true
    var index = 0
    var stream: Stream!

    // MARK: Actions

    @IBAction func presentAttachmentTapped(_ sender: Any) {
        guard let attachment = self.chunks[self.index].attachments.first else {
            return
        }
        AppDelegate.setImportedDocumentURL(to: attachment.url)
    }

    @IBAction func openAttachmentTapped(_ sender: Any) {
        guard let url = self.chunks[self.index].attachments.first?.url else {
            return
        }

        guard !url.pathExtension.isEmpty else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }

        self.statusIndicatorView.showLoading()
        let destination: DownloadRequest.DownloadFileDestination = { _, _ in
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let fileURL = caches.appendingPathComponent(url.lastPathComponent)
            return (fileURL, [.removePreviousFile, .createIntermediateDirectories])
        }
        Alamofire.download(url, to: destination).response { response in
            self.statusIndicatorView.hide()
            guard let url = response.destinationURL, response.error == nil else {
                return
            }
            self.documentInteractionController.url = url
            self.documentInteractionController.presentOpenInMenu(from: CGRect.zero, in: self.view, animated: true)
        }
    }

    @IBAction func optionsTapped(_ button: UIButton) {
        self.player?.pause()
        let chunk = self.chunks[self.index]
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addShareAction(chunk: chunk, presenter: self, reviewer: self)
        let faster = self.player?.rate == 1.0
        sheet.addAction(UIAlertAction(title: faster ? "Play Faster" : "Play Slower", style: .default) { _ in
            self.player?.rate = faster ? 1.5 : 1.0
        })
        sheet.addCancel()
        sheet.configurePopOver(sourceView: button, sourceRect: button.bounds)
        self.present(sheet, animated: true)
        Answers.logCustomEvent(withName: "Player Action", customAttributes: ["Action": "showOptions"])
    }

    @IBAction func toggleLoudspeakerTapped(_ sender: Any) {
        guard AudioService.instance.usingInternalSpeaker else {
            // Leave headphones etc alone.
            return
        }
        let useLoudspeaker = !SettingsManager.preferLoudspeaker
        SettingsManager.preferLoudspeaker = useLoudspeaker
        AudioService.instance.useLoudspeaker = useLoudspeaker
        self.updateLoudspeakerToggle()
    }

    @IBAction func showFeedbackTapped(_ sender: AnyObject) {
        self.toggleFeedbackView(show: true)
        Answers.logCustomEvent(withName: "Player Action", customAttributes: ["Action": "showDetails"])
    }

    @IBAction func likeTapped(_ sender: AnyObject) {
        guard let chunk = self.chunks[self.index] as? Chunk else {
            return
        }
        self.stream.setChunkReaction(chunk: chunk, reaction: Chunk.likeReaction)

        Answers.logCustomEvent(withName: "Player Action", customAttributes: ["Action": "thumbUp"])
    }

    @IBAction func dislikeTapped(_ sender: Any) {
        guard let chunk = self.chunks[self.index] as? Chunk else {
            return
        }
        self.stream.setChunkReaction(chunk: chunk, reaction: Chunk.dislikeReaction)

        Answers.logCustomEvent(withName: "Player Action", customAttributes: ["Action": "thumbDown"])
    }

    // MARK: - UIViewController

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override func viewDidLoad() {
        self.chunks = self.stream.chunks

        // Dismiss the page when swiping down.
        let downSwipe = UISwipeGestureRecognizer(target: self, action: #selector(StoryViewController.close))
        downSwipe.direction = .down
        self.playbackView.addGestureRecognizer(downSwipe)

        // Show feedback view when swiping up.
        let upSwipe = UISwipeGestureRecognizer(target: self, action: #selector(StoryViewController.handleSwipe(_:)))
        upSwipe.direction = .up
        self.playbackView.addGestureRecognizer(upSwipe)

        // Set up progress view
        self.view.layoutIfNeeded()

        // TODO: Refactor feedbackView into separate view class
        // Set up feedback view
        self.feedbackTableView.delegate = self
        self.feedbackTableView.dataSource = self
        self.feedbackOverlayView = UIView(frame: self.view.frame)
        self.feedbackOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        self.feedbackOverlayView.isHidden = true
        // Close the view when swiping down.
        let feedbackSwipe = UISwipeGestureRecognizer(target: self, action: #selector(StoryViewController.toggleFeedbackView(show:)))
        feedbackSwipe.direction = .down
        self.feedbackOverlayView.addGestureRecognizer(feedbackSwipe)
        self.feedbackOverlayView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(StoryViewController.toggleFeedbackView(show:))))
        self.view.insertSubview(self.feedbackOverlayView, aboveSubview: self.playbackView)
        self.updateFeedbackView()

        self.player = SwappingQueuePlayer(container: self.view)
        self.player!.delegate = self

        // Send background image view to the back
        self.view.insertSubview(self.backgroundImageView, at: 0)

        // Chunk navigation on tap
        self.playbackView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(StoryViewController.handlePlaybackViewTapped)))

        // Pause on long press
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(StoryViewController.handlePlaybackViewLongPress))
        longPress.minimumPressDuration = 0.15
        self.playbackView.addGestureRecognizer(longPress)

        self.subtitlesLabel.text = nil

        // Status indicator
        self.statusIndicatorView = StatusIndicatorView.create(container: self.view)

        self.progressSlider.setThumbImage(UIImage(named: "scrubber"), for: .normal)
        self.progressSlider.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(StoryViewController.handleProgressPan)))

        AppDelegate.userSelectedStream.addListener(self, method: StoryViewController.handleUserSelectedStream)
        CacheService.instance.urlCached.addListener(self, method: StoryViewController.handleURLCached)

        // Start playback
        self.play()
        // TODO: Use delegate pattern for this
        if !self.autoplay {
            self.toggleFeedbackView(show: true)
        }

        self.stream.changed.addListener(self, method: StoryViewController.refresh)
    }

    override func viewDidAppear(_ animated: Bool) {
        Answers.logCustomEvent(withName: "Active User", customAttributes: ["Reason": "play"])
        AppDelegate.applicationActiveStateChanged.addListener(self, method: StoryViewController.handleApplicationActiveStateChanged)
        if !self.waitingForCache && self.feedbackOverlayView.isHidden {
            self.player?.resume()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        self.stream.reportStatus(.idle)
        AppDelegate.applicationActiveStateChanged.removeListener(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        ProximityMonitor.instance.active = true
        UIApplication.shared.isIdleTimerDisabled = true
        // Ensure loudspeaker is configured correctly.
        AudioService.instance.useLoudspeaker = SettingsManager.preferLoudspeaker
        self.updateLoudspeakerToggle()
        // Add listener for rewinding whenever the route changes.
        VolumeMonitor.instance.routeChange.addListener(self, method: StoryViewController.handleRouteChange)
    }

    override func viewWillDisappear(_ animated: Bool) {
        ProximityMonitor.instance.active = false
        UIApplication.shared.isIdleTimerDisabled = false
        VolumeMonitor.instance.routeChange.removeListener(self)
    }

    override func viewWillLayoutSubviews() {
        self.player?.layout()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touchPoint = touches.first?.location(in: self.playbackView),
            touchPoint.x < self.rewindTouchThreshold && touchPoint.y > self.scrubberTouchThreshold else {
            return
        }
        self.rewindLabel.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 0.2, options: .curveEaseIn, animations: {
            self.rewindLabel.alpha = 0
        }, completion: nil)
    }

    // MARK: - SwappingQueuePlayerDelegate

    func playerDidFinishPlayingChunk(_ player: SwappingQueuePlayer) {
        self.nextChunk()
    }

    func player(_ player: SwappingQueuePlayer, offsetDidChange offset: TimeInterval) {
        if !player.isPaused {
            self.progressSlider.value = Float(offset / player.duration)
        }
        let chunk = self.chunks[self.index]
        let start = Int(offset / 4) * 4000, end = start + 4000
        self.subtitlesLabel.text = chunk.textSegments?.filter({ $0.start >= start && $0.start < end }).map({ $0.text }).joined(separator: " ")
    }

    // MARK: - ReviewDelegate

    func didFinishReviewing(reviewController: ReviewViewController, send: Bool) {
        reviewController.dismiss(animated: true, completion: nil)
        guard let recording = reviewController.recording, send else {
            return
        }
        recording.transcript.then {
            let chunk = Intent.Chunk(
                url: recording.fileURL,
                attachments: reviewController.attachments,
                duration: Int(recording.duration),
                externalContentId: nil,
                textSegments: $0)
            if let stream = reviewController.presetStream {
                stream.sendChunk(chunk)
            } else {
                StreamService.instance.broadcastChunk(
                    chunk,
                    streams: Array(reviewController.selectedStreams),
                    participants: Array(reviewController.selectedParticipants))
            }
        }
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // TODO: Handle selection
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let chunk = self.chunks[self.index]
        return self.stream.participantsPlayed(chunk: chunk).count + (chunk.externalPlays > 0 ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let chunk = self.chunks[self.index]
        let participants = self.stream.participantsPlayed(chunk: chunk)
        guard indexPath.row < participants.count else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "othersCell", for: indexPath) as! OthersCell
            if chunk.externalPlays == 1 {
                cell.label.text = "1 other viewer"
            } else {
                cell.label.text = "\(chunk.externalPlays) other viewers"
            }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "participantCell", for: indexPath) as! ParticipantCell
        let participant = participants[indexPath.row]
        cell.nameLabel.text = participant.displayName
        if let url = participant.imageURL {
            cell.avatarImageView.af_setImage(withURL: url)
        }
        cell.senderFlagLabel.isHidden = participant.id != chunk.senderId
        // Display reaction.
        if let chunk = chunk as? Chunk, let reaction = chunk.reactions[participant.id] {
            cell.reactionLabel.isHidden = false
            cell.reactionLabel.text = reaction == Chunk.likeReaction ? "thumb_up" : "thumb_down"
        } else {
            cell.reactionLabel.isHidden = true
        }
        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard section == 0 else {
            return nil
        }

        let chunk = self.chunks[self.index]
        let count = self.stream.participantsPlayed(chunk: chunk).count - 1 + chunk.externalPlays
        return  "SEEN (\(count))"
    }

    // MARK: - Private

    private lazy var documentInteractionController = UIDocumentInteractionController()

    private var chunks: [PlayableChunk]!
    private var feedbackOverlayView: UIView!
    private var player: SwappingQueuePlayer?
    private let rewindTouchThreshold = UIScreen.main.bounds.width / 4
    private var statusIndicatorView: StatusIndicatorView!
    private let scrubberTouchThreshold: CGFloat = 50
    private var waitingForCache = false

    private dynamic func close() {
        self.player?.pause()
        self.dismiss(animated: true) { _ in
            self.player = nil
        }
    }

    private dynamic func handlePlaybackViewTapped(recognizer: UITapGestureRecognizer) {
        // Do not handle taps where the scrubber is.
        let touchPoint = recognizer.location(ofTouch: 0, in: self.playbackView)
        guard self.playbackView.bounds.size.height - touchPoint.y > self.scrubberTouchThreshold else {
            return
        }

        if touchPoint.x < self.rewindTouchThreshold {
            self.previousChunk()
            Answers.logCustomEvent(withName: "Player Action", customAttributes: ["Action": "previous"])
        } else {
            self.nextChunk()
            Answers.logCustomEvent(withName: "Player Action", customAttributes: ["Action": "next"])
        }
    }

    private dynamic func handlePlaybackViewLongPress(recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            self.player?.pause()
            self.playbackView.hideAnimated()
            Answers.logCustomEvent(withName: "Player Action", customAttributes: ["Action": "pauseLongPress"])
        case .ended:
            self.player?.resume()
            self.playbackView.showAnimated()
        default:
            break
        }
    }

    private dynamic func handleProgressPan(recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            self.player?.pause()
            UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState, animations: {
                self.progressSlider.alpha = 1
            }, completion: nil)
        case .changed:
            let delta = Float(recognizer.translation(in: nil).x / 340)
            let newValue = self.progressSlider.value + delta
            self.progressSlider.value = newValue
            self.player?.seek(to: newValue)
            recognizer.setTranslation(.zero, in: nil)
        default:
            self.player?.resume()
            UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState, animations: {
                self.progressSlider.alpha = 0.3
            }, completion: nil)
       }
    }

    private dynamic func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard self.playbackView.bounds.size.height - recognizer.location(ofTouch: 0, in: self.playbackView).y > self.scrubberTouchThreshold else {
            return
        }

        switch recognizer.direction {
        case UISwipeGestureRecognizerDirection.up:
            self.toggleFeedbackView(show: true)
            Answers.logCustomEvent(withName: "Player Action", customAttributes: ["Action": "showDetailsSwipe"])
        default:
            break
        }
    }

    private dynamic func previousChunk() {
        guard self.index > 0 else {
            return
        }

        self.index -= 1
        self.play(isRewind: true)
    }

    private func nextChunk() {
        guard self.index < self.chunks.count - 1 else {
            self.close()
            return
        }
        self.index += 1
        self.play()
    }

    private func play(isRewind: Bool = false) {
        guard let player = self.player else {
            return
        }

        // Reset video progress
        self.progressSlider.value = 0

        let chunk = self.chunks[self.index]
        // TODO: We should only report when real playback begins.
        self.stream.reportStatus(.playing, estimatedDuration: Int(Float(chunk.duration) / SettingsManager.playbackRate))

        self.updateFeedbackView()
        self.subtitlesLabel.text = nil

        // Display the sender info.
        let participant = self.stream.getParticipant(chunk.senderId)
        self.senderNameLabel.text = participant?.displayName
        self.chunkTimestampLabel.text = NSDate(timeIntervalSince1970: TimeInterval(chunk.end) / 1000).shortTimeAgoSinceNow()
        if let url = participant?.imageURL {
            self.backgroundImageView.af_setImage(withURL: url)
        }

        // Get information about the next chunk and cache it if there is one.
        let nextLocalURL: URL?
        let waitingForNext: Bool
        if self.index < self.chunks.count - 1 {
            let chunk = self.chunks[self.index + 1]
            CacheService.instance.cache(chunk: chunk)
            nextLocalURL = CacheService.instance.getLocalURL(chunk.url)
            waitingForNext = !CacheService.instance.hasCached(url: chunk.url)
        } else {
            nextLocalURL = nil
            waitingForNext = false
        }

        // Ensure that the chunk data is available locally before continuing.
        guard CacheService.instance.hasCached(url: chunk.url) && !waitingForNext else {
            CacheService.instance.cache(chunk: chunk)
            // Show a loading state while caching.
            self.statusIndicatorView.showLoading()
            self.waitingForCache = true
            player.pause()
            return
        }

        // Everything is cached.
        self.waitingForCache = false
        self.statusIndicatorView.hide()

        // Update played until immediately if the chunk is unplayed.
        if !self.stream.isChunkPlayed(chunk) {
            self.stream.setPlayedUntil(chunk.end)
        }

        let localURL = CacheService.instance.getLocalURL(chunk.url)

        // Simulate the first offset change to 0 to trigger subtitles instantly.
        self.player(player, offsetDidChange: 0)
        player.play(url: localURL, next: nextLocalURL, isRewind: isRewind)
    }

    private func refresh() {
        // Update chunks in our local collection with the latest data
        for i in 0..<self.chunks.count {
            guard let old = self.chunks[i] as? Chunk,
                let new = self.stream.chunks.first(where: { ($0 as? Chunk)?.id == old.id }) else {
                    continue
            }
            self.chunks[i] = new
        }
        self.updateFeedbackView()
    }

    private dynamic func toggleFeedbackView(show: Bool = false) {
        guard show else {
            self.player?.resume()
            self.feedbackOverlayView.hideAnimated()
            UIView.animate(withDuration: 0.2) {
                self.feedbackView.transform = .identity
            }
            return
        }

        self.player?.pause()
        self.feedbackOverlayView.showAnimated()
        UIView.animate(
            withDuration: 0.5,
            delay: 0.0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.2,
            options: [.allowUserInteraction],
            animations: { self.feedbackView.transform = CGAffineTransform(translationX: 0, y: -400) },
            completion: nil)
    }

    private func updateFeedbackView() {
        if let chunk = self.chunks[self.index] as? Chunk {
            self.likeCountLabel.text = "(\(chunk.reactions.filter({ $0.value == Chunk.likeReaction }).count))"
            self.dislikeCountLabel.text = "(\(chunk.reactions.filter({ $0.value == Chunk.dislikeReaction }).count))"
        } else {
            self.likeCountLabel.text = "(0)"
            self.dislikeCountLabel.text = "(0)"
        }

        self.feedbackTableView.reloadData()
        if let title = self.chunks[self.index].attachments.first?.title {
            self.feedbackAttachmentView.isHidden = false
            self.attachmentButton.setTitleWithoutAnimation(title)
        } else {
            self.feedbackAttachmentView.isHidden = true
        }
    }

    private func updateLoudspeakerToggle() {
        if !AudioService.instance.usingInternalSpeaker {
            self.loudspeakerToggleButton.setTitle("headset", for: .normal)
        } else if AudioService.instance.useLoudspeaker {
            self.loudspeakerToggleButton.setTitle("volume_up", for: .normal)
        } else {
            self.loudspeakerToggleButton.setTitle("hearing", for: .normal)
        }
    }

    // MARK: - Events

    private func handleApplicationActiveStateChanged(active: Bool) {
        guard active else {
            self.player?.pause()
            return
        }

        if self.feedbackOverlayView.isHidden {
            self.player?.resume()
        }
    }

    private func handleRouteChange(volume: Float) {
        self.updateLoudspeakerToggle()
        self.player?.rewind(by: 1)
    }

    private func handleSelectedStreamChanged() {
        self.close()
    }

    private func handleURLCached(url: URL) {
        if self.waitingForCache {
            // Retry playback.
            // TODO: How to propagate isRewind?
            self.play()
        }
    }

    private func handleUserSelectedStream(stream: Stream) {
        if stream.id != self.stream.id {
            self.close()
        }
    }
}

class OthersCell: UITableViewCell {
    @IBOutlet weak var label: UILabel!

    override func prepareForReuse() {
        self.label.text = nil
    }
}

class ParticipantCell: UITableViewCell {
    @IBOutlet weak var nameLabel: UILabel!
    @IBOutlet weak var avatarImageView: UIImageView!
    @IBOutlet weak var senderFlagLabel: UILabel!
    @IBOutlet weak var reactionLabel: UILabel!

    override func awakeFromNib() {
        self.separator = CALayer()
        self.separator.backgroundColor = UIColor.lightGray.cgColor
        self.layer.addSublayer(self.separator)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.separator.frame = CGRect(x: 16, y: self.frame.height - 1, width: self.frame.width - 32, height: 0.5)
    }

    override func prepareForReuse() {
        self.nameLabel.text = nil
        self.senderFlagLabel.isHidden = true
        self.reactionLabel.isHidden = true
        self.avatarImageView.image = UIImage(named: "single")
    }

    private var separator: CALayer!
}

class ProgressSlider: UISlider {
    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        var newBounds = super.trackRect(forBounds: bounds)
        newBounds.size.height = 4
        return newBounds
    }
}
