import AVFoundation
import UIKit
import UserNotifications

class FeedViewController : UIViewController,
    PagerPage,
    ReviewDelegate,
    UITableViewDelegate,
    UITableViewDataSource,
    FeedCellDelegate,
    ConversationImportDelegate {

    @IBOutlet weak var emptyFeedView: UIView!
    @IBOutlet weak var searchBarView: BottomSeparatorView!
    @IBOutlet weak var searchField: SearchTextField!
    @IBOutlet weak var settingsButton: CameraControlButton!
    @IBOutlet weak var streamsTable: UITableView!
    @IBOutlet weak var titleImage: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var versionLabel: UILabel!
    @IBOutlet weak var versionLabelTop: NSLayoutConstraint!

    override func viewDidDisappear(_ animated: Bool) {
        // Make sure no previews are running while view is off-screen.
        self.streamsTable.visibleCells.forEach {
            guard let cell = $0 as? FeedStreamCell else { return }
            cell.stopChunkPreview()
        }
    }

    override func viewDidLoad() {
        self.streamsTable.delegate = self
        self.streamsTable.dataSource = self
        self.streamsTable.rowHeight = UITableViewAutomaticDimension
        self.streamsTable.keyboardDismissMode = .onDrag

        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(FeedViewController.tableLongPressed))
        self.streamsTable.addGestureRecognizer(longPressRecognizer)

        self.activeStreams = StreamService.instance.activeStreams.values

        AppDelegate.applicationActiveStateChanged.addListener(self, method: FeedViewController.handleActiveStateChanged)
        StreamService.instance.activeStreamsChanged.addListener(self, method: FeedViewController.handleActiveStreamsChanged)
        StreamService.instance.chunksChanged.addListener(self, method: FeedViewController.handleChunksChanged)
        StreamService.instance.sentChunk.addListener(self, method: FeedViewController.handleSentChunk)
    }

    override func viewWillAppear(_ animated: Bool) {
        // Highlight settings when notifications are not enabled.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus != .authorized {
                    self.settingsButton.backgroundColor = "ff3a3a".hexColor
                    self.settingsButton.titleLabel?.textColor = .white
                    self.showEnableNotifications = true
                } else {
                    self.settingsButton.backgroundColor = .clear
                    self.settingsButton.titleLabel?.textColor = .black
                    self.showEnableNotifications = false
                }
            }
        }
        // Restart playback of preview videos.
        self.streamsTable.visibleCells.forEach {
            guard let cell = $0 as? FeedStreamCell else { return }
            cell.startChunkPreview(delay: 0.1)
        }
        // Update name and image
        if let session = BackendClient.instance.session {
            self.titleLabel.text = session.displayName
            if let url = session.imageURL {
                self.titleImage.af_setImage(withURL: url, placeholderImage: UIImage(named: "single"))
            }
        }
    }

    // MARK: - Actions

    @IBAction func cameraTapped(_ sender: Any) {
        self.pager?.pageTo(.create)
    }

    @IBAction func closeSearchTapped(_ sender: Any) {
        self.searchBarView.hideAnimated()
        self.isSearching = false
        self.view.endEditing(true)
    }

    @IBAction func searchTapped(_ sender: Any) {
        self.searchBarView.alpha = 0
        self.searchField.becomeFirstResponder()
        self.searchBarView.showAnimated()
        self.isSearching = true
    }

    @IBAction func searchFieldEditingChanged(_ sender: Any) {
        self.searchTimer?.invalidate()
        self.searchTimer =
            Timer.scheduledTimer(timeInterval: 0.4,
                                 target: self,
                                 selector: #selector(FeedViewController.filterStreams),
                                 userInfo: nil,
                                 repeats: false)
    }

    @IBAction func settingsTapped(_ button: UIButton) {
        var actions = [UIAlertAction]()
        if self.showEnableNotifications {
            actions.append(UIAlertAction(title: "👉 Enable Notifications", style: .destructive) { _ in
                UIApplication.shared.open(URL(string: UIApplicationOpenSettingsURLString)!)
            })
        }

        let alert = ConversationImportAlert(title: nil, message: nil, importActions: [.invite, .createStream, .connectFromSlack], otherActions: actions, owner: self, delegate: self)

        alert.show()
        self.importAlert = alert
    }

    @IBAction func startConversationTapped(_ sender: Any) {
        self.pager?.pageTo(.create)
    }

    @IBAction func setNameTapped(_ sender: Any) {
        let setName = self.storyboard?.instantiateViewController(withIdentifier: "SetName")
        self.present(setName!, animated: true, completion: nil)
    }

    // MARK: - PagerPage

    var pager: Pager?

    func didPage(swiped: Bool) {
    }

    // MARK: - ConversationImportDelegate

    var conversationImportAnchorView: UIView {
        return self.settingsButton
    }

    func conversationImport(didCreateStream stream: Stream) {
        self.pager?.pageTo(.create)
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

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let scrollY = -scrollView.contentOffset.y
        guard scrollY >= 10 else {
            self.versionLabel.isHidden = true
            return
        }
        if self.versionLabel.isHidden {
            let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?.?.?"
            let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "???"
            self.versionLabel.text = "☕️ fika.io v\(version) (\(build))"
        }
        self.versionLabelTop.constant = 40 + scrollY / 2
        let progress = min((scrollY - 10) / 60, 1)
        self.versionLabel.alpha = progress
        self.versionLabel.transform = CGAffineTransform(scaleX: progress, y: progress)
        self.versionLabel.isHidden = false
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let story = self.storyboard?.instantiateViewController(withIdentifier: "Story") as? StoryViewController,
            let cell = tableView.cellForRow(at: indexPath) as? FeedStreamCell,
            let stream = cell.stream
            else { return }
        story.stream = stream
        // Play the chunk that is being displayed as the current preview.
        story.index = cell.displayChunkIndex ?? 0
        story.autoplay = true
        self.present(story, animated: true, completion: nil)
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        // An iOS bug causes the UITableView to "forget" its scroll position upon navigation.
        // This needs to be as close as possible to the actual cell size to mitigate this.
        guard indexPath.section != 0 || indexPath.row != 0 || self.streams.first?.isExternalShare != true else {
            // The "Shared Videos" row is much smaller.
            return 114
        }
        return 240
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return self.streams.count
        default:
            return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let stream = self.streams[indexPath.row]
        let identifier = stream.isExternalShare ? "ShareCell" : "ConversationCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath) as! FeedStreamCell
        cell.stream = stream
        cell.delegate = self
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        self.streams[indexPath.row].changed.addListener(self, method: FeedViewController.handleStreamChanged)
        (cell as? FeedStreamCell)?.startChunkPreview()
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard self.streams.count > indexPath.row else {
            return
        }
        self.streams[indexPath.row].changed.removeListener(self)
        (cell as? FeedStreamCell)?.stopChunkPreview()
    }

    // MARK: - FeedCellDelegate

    var searchFilter: String? {
        return self.isSearching ? self.searchField.text : nil
    }

    func showDetails(for stream: Stream) {
        let chunks = self.storyboard?.instantiateViewController(withIdentifier: "Chunks") as! ChunksViewController
        chunks.stream = stream
        // TODO: Find a better way to send an initial filter
        chunks.presetFilter = self.searchFilter
        self.navigationController?.pushViewController(chunks, animated: true)
    }

    func reply(to stream: Stream) {
        let create = self.storyboard?.instantiateViewController(withIdentifier: "Creation") as! CreationViewController
        create.presetStream = stream
        self.present(create, animated: true, completion: nil)
    }

    func reload() {
        // Trigger size change
        self.streamsTable.beginUpdates()
        self.streamsTable.endUpdates()
    }

    // MARK: - Private

    private var activeStreams = [Stream]() {
        didSet {
            self.emptyFeedView.isHidden = !self.activeStreams.isEmpty
        }
    }

    private var importAlert: ConversationImportAlert?
    private var searchResultStreams: [Stream] = []
    private var searchTimer: Timer?

    private var isSearching = false {
        didSet {
            if !self.isSearching {
                self.searchResultStreams = []
            }
            self.searchTimer?.invalidate()
            self.searchField.text = nil
            self.streamsTable.reloadData()
        }
    }

    private var showEnableNotifications = false

    private var streams: [Stream] {
        return self.isSearching ? self.searchResultStreams : self.activeStreams
    }

    private dynamic func filterStreams() {
        defer {
            self.streamsTable.reloadData()
        }

        // TODO: Refactor matching logic to be shared across the app
        guard let filter = self.searchField.text?.lowercased(), !filter.trimmingCharacters(in: NSCharacterSet.whitespaces).isEmpty else {
            self.searchResultStreams = []
            return
        }

        let match: (String?) -> Bool = { text in
            return text?.lowercased().range(of: filter) != nil
        }

        var results = [(Stream, PlayableChunk)]()
        self.activeStreams.forEach { stream in
            if let chunk = stream.chunks.reversed().first(where: { chunk in
                let participant = stream.getParticipant(chunk.senderId)
                // Match sender name or transcript text to the search term
                guard match(participant?.displayName) || match(chunk.transcript) else {
                    return false
                }
                return true
            }) {
                results.append((stream, chunk))
            }
        }
        // Order the streams by latest matching chunk first and older chunks later
        self.searchResultStreams = results
            .sorted(by: {$0.1.end > $1.1.end })
            .map { $0.0 }
    }

    private dynamic func tableLongPressed(recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self.streamsTable)
        guard
            recognizer.state == .began,
            let indexPath = self.streamsTable.indexPathForRow(at: point),
            indexPath.section == 0,
            let cell = self.streamsTable.cellForRow(at: indexPath) as? FeedStreamCell,
            let stream = cell.stream
            else { return }
        let sheet = UIAlertController(title: stream.title, message: nil, preferredStyle: .actionSheet)
        if stream.isGroup && !stream.isExternalShare {
            sheet.message = stream.otherParticipants.map({ $0.displayName }).joined(separator: ", ")
            if sheet.message == "" {
                sheet.message = "You’re the only one here"
            }
        }
        if !stream.isExternalShare {
            sheet.addPingAction(stream: stream)
        }
        if let chunk = cell.displayChunk {
            sheet.addShareAction(chunk: chunk, presenter: self, reviewer: self)
            if stream.isGroup {
                sheet.addReplyActionIfNotSelf(stream: stream, chunk: chunk, presenter: self)
            }
        }
        if !stream.isExternalShare {
            sheet.addHideAction(stream: stream)
        }
        sheet.addCancel()
        let rect = CGRect(origin: recognizer.location(in: cell), size: .zero).insetBy(dx: -10, dy: -10)
        sheet.configurePopOver(sourceView: cell, sourceRect: rect)
        self.present(sheet, animated: true)
    }

    // MARK: - Events

    private func handleActiveStateChanged(active: Bool) {
        self.streamsTable.visibleCells.forEach {
            guard let cell = $0 as? FeedStreamCell else { return }
            if active {
                cell.startChunkPreview(delay: 0.1)
            } else {
                cell.stopChunkPreview()
            }
        }
    }

    private func handleActiveStreamsChanged(newActiveStreams: [Stream], diff: StreamService.StreamsDiff) {
        self.activeStreams = newActiveStreams

        // Update table view with animations.
        self.streamsTable.beginUpdates()
        self.streamsTable.insertRows(at: diff.inserted.map { IndexPath(row: $0, section: 0) }, with: .automatic)
        self.streamsTable.deleteRows(at: diff.deleted.map { IndexPath(row: $0, section: 0) }, with: .automatic)
        diff.moved.forEach { from, to in
            self.streamsTable.moveRow(at: IndexPath(row: from, section: 0), to: IndexPath(row: to, section: 0))
        }
        self.streamsTable.endUpdates()

        // Scroll to top.
        self.scrollToTop()
    }

    private func handleStreamChanged() {
        self.streamsTable.beginUpdates()
        self.streamsTable.endUpdates()
    }

    private func handleChunksChanged(newChunks: [Chunk], diff: StreamService.ChunksDiff) {
        self.scrollToTop()
    }

    private func handleSentChunk(stream: Stream, chunk: SendableChunk) {
        self.scrollToTop()
    }

    private func scrollToTop() {
        guard self.streams.count > 0 else {
            return
        }
        self.streamsTable.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
    }
}

protocol FeedCellDelegate: class {
    var searchFilter: String? { get }

    func showDetails(for stream: Stream)
    func reply(to stream: Stream)
}

class FeedStreamCell: UITableViewCell {
    @IBOutlet weak var loadingSpinner: UIActivityIndicatorView!
    @IBOutlet weak var playArrowLabel: UILabel!
    @IBOutlet weak var previewView: UIView!
    @IBOutlet weak var seenCountLabel: UILabel!
    @IBOutlet weak var senderImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!

    weak var delegate: FeedCellDelegate?
    private(set) var previewURL: URL?

    var displayChunkIndex: Int? {
        guard let stream = self.stream, let chunks = stream.chunks else {
            return nil
        }
        if let filter = self.delegate?.searchFilter {
            // TODO: Do not repeat matching logic.
            let match: (String?) -> Bool = { text in
                return text?.lowercased().range(of: filter) != nil
            }
            for i in (0..<chunks.endIndex).reversed() {
                let chunk = chunks[i]
                let participant = stream.getParticipant(chunk.senderId)
                // Match sender name or transcript text to the search term.
                if match(participant?.displayName) || match(chunk.transcript) {
                    return i
                }
            }
            return nil
        }
        var unplayedIndex = -1
        for i in (0..<chunks.endIndex).reversed() {
            let chunk = chunks[i]
            guard !chunk.byCurrentUser else {
                continue
            }
            if !stream.isChunkPlayed(chunk) {
                unplayedIndex = i
            } else if unplayedIndex > -1 {
                return unplayedIndex
            }
        }
        return chunks.endIndex - 1
    }

    var displayChunk: PlayableChunk? {
        get {
            guard
                let index = self.displayChunkIndex,
                let chunks = self.stream?.chunks,
                chunks.endIndex > index
                else { return nil }
            return self.stream?.chunks[index]
        }
    }

    var stream: Stream? {
        didSet {
            guard !(oldValue === self.stream) else {
                return
            }
            oldValue?.changed.removeListener(self)
            self.stream?.changed.addListener(self, method: FeedStreamCell.performRefresh)
            self.refresh()
        }
    }

    func refresh() {
        guard let stream = self.stream, let chunk = self.displayChunk else {
            return
        }

        let count = stream.participantsPlayed(chunk: chunk).count - 1 + chunk.externalPlays
        self.seenCountLabel.text = count.description
        self.titleLabel.text = stream.title

        // Show avatar while loading.
        self.loadingSpinner.startAnimating()
        self.playArrowLabel.isHidden = true
        let avatarTimer = Timer(timeInterval: 0.1, repeats: false) { _ in
            if let url = stream.getParticipant(chunk.senderId)?.imageURL {
                self.senderImageView.af_setImage(withURL: url, placeholderImage: UIImage(named: "single"))
            } else {
                self.senderImageView.image = UIImage(named: "single")
            }
        }
        RunLoop.main.add(avatarTimer, forMode: .commonModes)

        CacheService.instance.getThumbnail(for: chunk) { image in
            avatarTimer.invalidate()
            guard self.displayChunk?.url == chunk.url else {
                return
            }
            self.loadingSpinner.stopAnimating()
            self.playArrowLabel.isHidden = false
            guard let image = image else {
                return
            }
            self.senderImageView.af_cancelImageRequest()
            self.senderImageView.image = image
        }

        // If the player is currently active, ensure the current display chunk matches the one it is playing.
        if self.previewURL != nil {
            self.startChunkPreview()
        }
    }

    func startChunkPreview(delay: TimeInterval = 0.75, force: Bool = false) {
        guard let player = self.playerLayer.player, let chunk = self.displayChunk else {
            // Nothing to display, so cancel everything.
            NotificationCenter.default.removeObserver(self)
            self.previewTimer?.invalidate()
            self.previewURL = nil
            return
        }

        let localURL = CacheService.instance.getLocalURL(chunk.url)
        if let asset = player.currentItem?.asset as? AVURLAsset, asset.url == localURL {
            // No replacement necessary.
            player.play()
            self.previewTimer?.invalidate()
            self.previewURL = localURL
            return
        }

        if player.currentItem != nil {
            player.replaceCurrentItem(with: nil)
        }

        guard force || self.previewURL != localURL else {
            // No change since last call of this method.
            return
        }

        // The player needs to be updated to play the chunk.
        NotificationCenter.default.removeObserver(self)
        self.previewTimer?.invalidate()
        self.previewURL = localURL

        guard CacheService.instance.hasCached(url: chunk.url) else {
            // Cache the chunk, then retry.
            CacheService.instance.cache(chunk: chunk) { error in
                guard error == nil else { return }
                self.startChunkPreview(delay: 0.01, force: true)
            }
            return
        }

        self.previewTimer = Timer(timeInterval: delay, repeats: false) { _ in
            DispatchQueue.global(qos: .background).async {
                guard self.previewURL == localURL else {
                    return
                }
                let playerItem = AVPlayerItem(url: localURL)
                guard playerItem.asset.tracks(withMediaType: AVMediaTypeVideo).first != nil else {
                    return
                }
                player.replaceCurrentItem(with: playerItem)
                player.play()
                // Loop player.
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(FeedStreamCell.playerItemDidReachEnd(_:)),
                    name: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem)
            }
        }
        RunLoop.main.add(self.previewTimer!, forMode: .commonModes)
    }

    func stopChunkPreview() {
        self.playerLayer.player?.replaceCurrentItem(with: nil)
        self.previewTimer?.invalidate()
        self.previewTimer = nil
        self.previewURL = nil
    }

    // MARK: - Actions

    @IBAction func showDetailsTapped(_ sender: Any) {
        guard let stream = self.stream else {
            return
        }
        self.delegate?.showDetails(for: stream)
    }

    // MARK: - UITableViewCell

    override func prepareForReuse() {
        self.backgroundColor = .white
        self.loadingSpinner.stopAnimating()
        self.playArrowLabel.isHidden = false
        self.seenCountLabel.text = "0"
        self.senderImageView.af_cancelImageRequest()
        self.senderImageView.image = UIImage(named: "single")
        self.stream = nil
        self.titleLabel.text = ""

        NotificationCenter.default.removeObserver(self)

        self.stopChunkPreview()
        if let player = self.playerLayer.player, player.currentItem != nil {
            player.replaceCurrentItem(with: nil)
        }
    }

    // MARK: - UIView

    override func awakeFromNib() {
        let player = AVPlayer()
        player.actionAtItemEnd = .none
        player.isMuted = true
        self.playerLayer = AVPlayerLayer(player: player)
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill
        self.previewView.layer.addSublayer(self.playerLayer)
        self.separator = CALayer()
        self.separator.backgroundColor = UIColor(white: 0.95, alpha: 1).cgColor
        self.layer.addSublayer(self.separator)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.playerLayer.frame = self.previewView.bounds
        self.separator.frame = CGRect(x: 0, y: self.frame.height - 8, width: self.frame.width, height: 8)
    }

    // MARK: - Private

    private var playerLayer: AVPlayerLayer!
    private var previewTimer: Timer?
    private var separator: CALayer!

    private func performRefresh() {
        self.refresh()
    }

    private dynamic func playerItemDidReachEnd(_ notification: NSNotification) {
        (notification.object as? AVPlayerItem)?.seek(to: kCMTimeZero)
    }
}

class FeedConversationCell: FeedStreamCell {
    @IBOutlet weak var dislikeButton: UIButton!
    @IBOutlet weak var dislikeCountLabel: UILabel!
    @IBOutlet weak var likeButton: UIButton!
    @IBOutlet weak var likeCountLabel: UILabel!
    @IBOutlet weak var timestampLabel: UILabel!
    @IBOutlet weak var transcriptLabel: UILabel!

    override func refresh() {
        super.refresh()

        guard let stream = self.stream, let chunk = self.displayChunk else {
            return
        }

        let sender = stream.getParticipant(chunk.senderId)
        self.timestampLabel.text = chunk.endDate.timeLabelShort

        // Prepare the transcript.
        var preview = ""
        if let transcript = chunk.transcript {
            self.transcriptLabel.font = UIFont.systemFont(ofSize: 14)
            preview = transcript
        } else {
            self.transcriptLabel.font = UIFont.italicSystemFont(ofSize: 14)
            preview = "Tap to play."
        }
        if sender?.isCurrentUser == true || !stream.isDuo {
            let senderName: String
            if let sender = sender {
                senderName = sender.isCurrentUser ? "You" : sender.displayName
            } else {
                senderName = "Unavailable"
            }
            preview = "\(senderName): \(preview)"
        }

        // Conversation title.
        var title = stream.title
        if stream.isGroup {
            title.append(" (\(stream.otherParticipants.count + 1))")
        }

        // Reaction.
        // TODO: Support multiple reaction types.
        let reaction = chunk.userReaction
        let likeColor: UIColor = reaction == Chunk.likeReaction ? .fikaBlue : .darkGray
        self.likeButton.setTitleColor(likeColor, for: .normal)
        self.likeCountLabel.textColor = likeColor
        let dislikeColor: UIColor = reaction == Chunk.dislikeReaction ? .fikaBlue : .darkGray
        self.dislikeButton.setTitleColor(dislikeColor, for: .normal)
        self.dislikeCountLabel.textColor = dislikeColor

        self.likeCountLabel.text = "(\(chunk.reactions.filter({ $0.value == Chunk.likeReaction }).count))"
        self.dislikeCountLabel.text = "(\(chunk.reactions.filter({ $0.value == Chunk.dislikeReaction }).count))"

        // Highlight search term if a match is found.
        if let filter = self.delegate?.searchFilter {
            self.titleLabel.attributedText = title.highlightingMatches(of: filter)
            self.transcriptLabel.attributedText = preview.highlightingMatches(of: filter)
        } else {
            self.titleLabel.text = title
            self.transcriptLabel.text = preview
        }

        // Highlight unplayed content.
        self.backgroundColor = stream.isChunkPlayed(chunk) ? UIColor.white : UIColor.fikaBlue.withAlphaComponent(0.1)
    }

    // MARK: - Actions

    @IBAction func likeTapped(_ sender: Any) {
        guard let chunk = self.displayChunk as? Chunk else { return
        }
        self.likeButton.pulse()
        self.stream?.setChunkReaction(chunk: chunk, reaction: Chunk.likeReaction)
    }

    @IBAction func dislikeTapped(_ sender: Any) {
        guard let chunk = self.displayChunk as? Chunk else { return
        }
        self.dislikeButton.pulse()
        self.stream?.setChunkReaction(chunk: chunk, reaction: Chunk.dislikeReaction)
    }

    @IBAction func replyTapped(_ sender: Any) {
        guard let stream = self.stream else {
            return
        }
        self.delegate?.reply(to: stream)
    }

    // MARK: - UITableViewCell

    override func prepareForReuse() {
        super.prepareForReuse()
        self.timestampLabel.text = nil
        self.transcriptLabel.text = nil
    }
}

class FeedShareCell: FeedStreamCell {
}
