import Speech
import UIKit

private let timeEmoji = ["🕓", "🕰", "⌚️", "⏲", "⏱", "💭", "💬", "🗯", "🎉", "🔑", "👍", "🔥"]

class ChunksViewController: UIViewController, PagerPage, ReviewDelegate, UITableViewDelegate, UITableViewDataSource {

    @IBOutlet weak var backButton: UIButton!
    @IBOutlet weak var chunksTable: UITableView!
    @IBOutlet weak var emptyView: UIView!
    @IBOutlet weak var searchBarView: BottomSeparatorView!
    @IBOutlet weak var searchField: SearchTextField!
    @IBOutlet weak var syncReminderLabel: UILabel!
    @IBOutlet weak var timeLabel: UILabel!
    @IBOutlet weak var timeLabelTop: NSLayoutConstraint!
    @IBOutlet weak var titleLabel: UILabel!

    var pager: Pager?
    var presetFilter: String?
    var stream: Stream!

    override func viewDidLoad() {
        self.chunksTable.delegate = self
        self.chunksTable.dataSource = self
        self.chunksTable.rowHeight = UITableViewAutomaticDimension
        self.chunksTable.keyboardDismissMode = .onDrag
        self.chunksTable.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 110, right: 0)

        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(ChunksViewController.tableLongPressed))
        self.chunksTable.addGestureRecognizer(longPressRecognizer)

        if let stream = self.stream {
            StreamService.instance.loadStreamChunks(for: stream.id)
            stream.changed.addListener(self, method: ChunksViewController.refresh)
        }

        // TODO: Revisit preset filter concept
        if let filter = self.presetFilter {
            self.presetFilter = nil
            self.isSearching = true
            self.searchField.text = filter
            self.filterChunks()
        } else {
            self.refresh()
        }

        AppDelegate.userSelectedStream.addListener(self, method: ChunksViewController.handleUserSelectedStream)
    }

    override func viewDidLayoutSubviews() {
        // Scroll to relevant content on each layout pass.
        // Stop this behavior once everything has been laid out once.
        guard self.shouldScrollOnLayout else {
            return
        }
        self.scrollToRelevantContent(animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        self.shouldScrollOnLayout = false
    }

    // MARK: - Actions

    @IBAction func backTapped(_ sender: AnyObject) {
        let _ = self.navigationController?.popViewController(animated: true)
    }

    @IBAction func moreTapped(_ sender: UIButton) {
        self.playChunk(at: IndexPath(row: sender.tag, section: 0), showDetails: true)
    }

    @IBAction func closeSearchTapped(_ sender: AnyObject) {
        self.searchBarView.hideAnimated()
        self.isSearching = false
        self.chunksTable.backgroundColor = UIColor.white
        self.view.endEditing(true)
    }

    @IBAction func searchTapped(_ sender: AnyObject) {
        self.searchBarView.alpha = 0
        self.searchField.becomeFirstResponder()
        self.searchBarView.showAnimated()
        self.isSearching = true
        self.chunksTable.backgroundColor = UIColor.fikaGray
    }

    @IBAction func shareUpdateTapped(_ sender: Any) {
        guard let stream = self.stream else {
            return
        }
        let creation = self.storyboard?.instantiateViewController(withIdentifier: "Creation") as! CreationViewController
        creation.presetStream = stream
        self.present(creation, animated: true, completion: nil)
    }

    @IBAction func searchFieldEditingChanged(_ sender: AnyObject) {
        self.searchTimer?.invalidate()
        self.searchTimer =
            Timer.scheduledTimer(timeInterval: 0.4,
                                 target: self,
                                 selector: #selector(ChunksViewController.filterChunks),
                                 userInfo: nil,
                                 repeats: false)
    }

    @IBAction func settingsTapped(_ button: UIButton) {
        let names = self.stream.isGroup ? self.stream.otherParticipants.map({ $0.displayName }).joined(separator: ", ") : nil
        let sheet = UIAlertController(title: self.stream.title, message: names, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Ping", style: .default, handler: { _ in
            Intent.buzz(streamId: self.stream.id).perform(BackendClient.instance)
        }))
        sheet.addAction(UIAlertAction(title: "Schedule Sync", style: .default) { _ in
            let createMeeting = self.storyboard?.instantiateViewController(withIdentifier: "CreateMeeting") as! CreateMeetingViewController
            createMeeting.stream = self.stream
            self.present(createMeeting, animated: true, completion: nil)
        })
        sheet.addAction(UIAlertAction(title: "Set Transcription Language", style: .default) { _ in
            let subsheet = UIAlertController(title: "Pick language", message: nil, preferredStyle: .actionSheet)
            let currentId = self.stream.transcriptionLocale.identifier
            SFSpeechRecognizer.supportedLocales().sorted(by: { $0.0.identifier < $0.1.identifier }).forEach { locale in
                let name = Locale.current.localizedString(forIdentifier: locale.identifier)
                subsheet.addAction(UIAlertAction(title: locale.identifier == currentId ? "• \(name!)" : name, style: .default) { _ in
                    self.stream.transcriptionLocale = locale
                })
            }
            subsheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(subsheet, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = button
            popover.sourceRect = button.bounds
        }
        self.present(sheet, animated: true)
    }

    // MARK: - PagerPage

    func didPage(swiped: Bool) {
        // Autoplay any unplayed stream where the chunk is already preloaded,
        // only if entering the page programmatically (not a swipe).
        guard !swiped, let stream = self.stream, stream.isUnplayed else {
            return
        }
        let startIndex = self.chunks.index(where: { !stream.isChunkPlayed($0) }) ?? 0
        guard CacheService.instance.hasCached(url: self.chunks[startIndex].url) else {
            return
        }
        self.playChunk(at: self.path(chunk: startIndex))
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
        guard scrollY >= 10, let stream = self.stream else {
            self.timeLabel.isHidden = true
            return
        }
        if self.timeLabel.isHidden {
            let formatter = DateComponentsFormatter()
            formatter.maximumUnitCount = 2
            formatter.unitsStyle = .full
            let i = Int(arc4random_uniform(UInt32(timeEmoji.count)))
            self.timeLabel.text = "\(timeEmoji[i]) \(formatter.string(from: stream.totalDuration)!)!"
        }
        self.timeLabelTop.constant = 40 + scrollY / 2
        let progress = min((scrollY - 10) / 60, 1)
        self.timeLabel.alpha = progress
        self.timeLabel.transform = CGAffineTransform(scaleX: progress, y: progress)
        self.timeLabel.isHidden = false
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        self.playChunk(at: indexPath)
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return 120
    }

    // MARK: UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return self.chunks.count > 0 ? 2 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return self.chunks.count
        default:
            return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let stream = self.stream, let chunk = self.chunk(for: indexPath) else {
            preconditionFailure("could not get chunk")
        }
        let sender = stream.getParticipant(chunk.senderId)

        let cell = tableView.dequeueReusableCell(withIdentifier: "ChunkCell", for: indexPath) as! ChunkCell
        cell.loadingSpinner.startAnimating()
        cell.senderImageView.image = nil
        cell.tag = indexPath.row
        CacheService.instance.getThumbnail(for: chunk) { image in
            guard cell.tag == indexPath.row else {
                return
            }
            cell.loadingSpinner.stopAnimating()
            guard let image = image else {
                if let url = sender?.imageURL {
                    cell.senderImageView.af_setImage(withURL: url, placeholderImage: UIImage(named: "single"))
                } else {
                    cell.senderImageView.image = UIImage(named: "single")
                }
                return
            }
            cell.senderImageView.image = image
        }
        cell.timestampLabel.text = NSDate(timeIntervalSince1970: TimeInterval(chunk.end) / 1000).shortTimeAgoSinceNow()

        // Show defaults for sender name and transcript.
        let senderName = sender?.displayName ?? "Unavailable"
        // Highlight matches if something is being searched.
        if let search = self.searchField.text?.lowercased(), self.isSearching {
            cell.transcriptionLabel.attributedText = (chunk.transcript ?? "").highlightingMatches(of: search)
            cell.senderNameLabel.attributedText = senderName.highlightingMatches(of: search)
        } else {
            if let transcript = chunk.transcript {
                cell.transcriptionLabel.font = UIFont.systemFont(ofSize: 14)
                cell.transcriptionLabel.text = transcript
            } else {
                cell.transcriptionLabel.font = UIFont.italicSystemFont(ofSize: 14)
                cell.transcriptionLabel.text = "Tap to play."
            }
            cell.senderNameLabel.text = senderName
        }

        // Show unplayed content in light gray instead of black.
        if !stream.isChunkPlayed(chunk) {
            cell.backgroundColor = UIColor.fikaBlue.withAlphaComponent(0.1)
            let unplayed = stream.unplayedChunks
            cell.isNewLabelHidden =
                self.isSearching || (unplayed.first as? Chunk)?.id != (chunk as? Chunk)?.id
            cell.newLabel.text = String(format: "%i new update%@", unplayed.count, unplayed.count == 1 ? "" : "s")
        }

        let count = stream.participantsPlayed(chunk: chunk).count - 1 + chunk.externalPlays
        cell.seenCountLabel.text = count.description
        cell.moreButton.tag = indexPath.row
        if let chunk = chunk as? Chunk {
            let reaction = chunk.userReaction
            let likeColor: UIColor = reaction == Chunk.likeReaction ? .fikaBlue : .lightGray
            cell.likeIconLabel.textColor = likeColor
            cell.likeCountLabel.textColor = likeColor
            let dislikeColor: UIColor = reaction == Chunk.dislikeReaction ? .fikaBlue : .lightGray
            cell.dislikeIconLabel.textColor = dislikeColor
            cell.dislikeCountLabel.textColor = dislikeColor

            cell.likeCountLabel.text = chunk.reactions.filter({ $0.value == Chunk.likeReaction }).count.description
            cell.dislikeCountLabel.text = chunk.reactions.filter({ $0.value == Chunk.dislikeReaction }).count.description
        }
        return cell
    }

    // MARK: - Private

    private var searchResultChunks: [PlayableChunk] = []
    private var searchTimer: Timer?
    private var isSearching = false {
        didSet {
            self.searchResultChunks = []
            self.searchTimer?.invalidate()
            self.searchField.text = nil
            self.refresh()
        }
    }
    private var shouldScrollOnLayout = true

    private var chunks: [PlayableChunk] {
        get {
            return self.isSearching ? self.searchResultChunks : self.stream?.chunks ?? []
        }
    }

    private func chunk(at index: Int) -> PlayableChunk? {
        if !self.isSearching {
            return self.chunks[index]
        }
        // Invert the order of chunks while searching.
        guard 0..<self.chunks.count ~= index else {
            return nil
        }
        return self.chunks[self.chunks.count - 1 - index]
    }

    private func chunk(for indexPath: IndexPath) -> PlayableChunk? {
        guard indexPath.section == 0 else {
            return nil
        }
        return self.chunk(at: indexPath.row)
    }

    private func path(chunk index: Int) -> IndexPath {
        return IndexPath(row: index, section: 0)
    }

    private func refresh() {
        let chunksCount = self.chunks.count
        self.emptyView.isHidden = self.isSearching || chunksCount > 0
        self.titleLabel.text = self.stream?.title ?? "History"
        self.syncReminderLabel.isHidden = !(self.stream?.currentUserDidMissSync ?? false)

        let shouldScroll = self.chunksTable.numberOfRows(inSection: 0) != chunksCount
        self.chunksTable.reloadData()
        if shouldScroll {
            self.scrollToRelevantContent(animated: true)
        }
    }

    private func playChunk(at indexPath: IndexPath, showDetails: Bool = false) {
        guard
            let stream = self.stream,
            let story = self.storyboard?.instantiateViewController(withIdentifier: "Story") as? StoryViewController,
            let chunk = self.chunk(for: indexPath) as? Chunk
            else { return }
        story.stream = stream
        story.index = stream.chunks.index(where: { ($0 as? Chunk)?.id == chunk.id }) ?? 0
        story.autoplay = !showDetails
        self.present(story, animated: true, completion: nil)
    }

    private func playStream() {
        guard let row = self.stream.chunks.index(where: { !self.stream.isChunkPlayed($0) }) else {
            return
        }
        self.playChunk(at: IndexPath(row: row, section: 0))
    }

    private dynamic func tableLongPressed(recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self.chunksTable)
        guard
            recognizer.state == .began,
            let indexPath = self.chunksTable.indexPathForRow(at: point),
            indexPath.section == 0,
            let cell = self.chunksTable.cellForRow(at: indexPath),
            let stream = self.stream,
            let chunk = self.chunk(for: indexPath) as? Chunk
            else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addOpenAttachmentActionIfApplicable(chunk: chunk)
        sheet.addLikeAction(stream: stream, chunk: chunk)
        sheet.addShareAction(chunk: chunk, presenter: self, reviewer: self)
        sheet.addReplyActionIfNotSelf(stream: stream, chunk: chunk, presenter: self)
        sheet.addCancel()
        let rect = CGRect(origin: recognizer.location(in: cell), size: .zero).insetBy(dx: -10, dy: -10)
        sheet.configurePopOver(sourceView: cell, sourceRect: rect)
        self.present(sheet, animated: true)
    }

    private dynamic func filterChunks() {
        defer {
            self.chunksTable.reloadData()
        }
        
        guard let stream = self.stream, let filter = self.searchField.text?.lowercased(), !filter.trimmingCharacters(in: NSCharacterSet.whitespaces).isEmpty else {
            self.searchResultChunks = []
            return
        }

        let match: (String?) -> Bool = { text in
            return text?.lowercased().range(of: filter) != nil
        }
        self.searchResultChunks = stream.chunks.filter {
            let participant = stream.getParticipant($0.senderId)
            // Match sender name or transcript text to the search term
            guard match(participant?.displayName) || match($0.transcript) else {
                return false
            }
            return true
        }
    }

    /// Scroll either to the last row or the first unplayed row
    private func scrollToRelevantContent(animated: Bool) {
        let rowCount = self.chunksTable.numberOfRows(inSection: 0)
        guard rowCount > 0 else {
            return
        }

        // TODO: Don't do this on every refresh since they can come in very often.
        if let stream = self.stream, let firstUnplayed = self.chunks.index(where: { !stream.isChunkPlayed($0) }) {
            self.chunksTable.scrollToRow(at: self.path(chunk: firstUnplayed), at: .top, animated: animated)
        } else {
            self.chunksTable.scrollToRow(at: IndexPath(row: rowCount - 1, section: 0), at: .top, animated: animated)
        }
    }

    private func handleUserSelectedStream(stream: Stream) {
        guard self.stream.id != stream.id else {
            return
        }
        self.dismiss(animated: true, completion: nil)
        self.stream = stream
        self.refresh()
        self.scrollToRelevantContent(animated: true)
    }
}

class ChunkCell: SeparatorCell {
    @IBOutlet weak var loadingSpinner: UIActivityIndicatorView!
    @IBOutlet weak var moreButton: UIButton!
    // TODO: Combine reaction icon + count into 1 component
    @IBOutlet weak var dislikeIconLabel: UILabel!
    @IBOutlet weak var dislikeCountLabel: UILabel!
    @IBOutlet weak var likeCountLabel: UILabel!
    @IBOutlet weak var likeIconLabel: UILabel!
    @IBOutlet weak var seenCountLabel: UILabel!
    @IBOutlet weak var senderImageView: UIImageView!
    @IBOutlet weak var senderNameLabel: UILabel!
    @IBOutlet weak var timestampLabel: UILabel!
    @IBOutlet weak var transcriptionLabel: UILabel!
    @IBOutlet weak var newLabel: UILabel!
    @IBOutlet weak var newLabelHeightConstraint: NSLayoutConstraint!

    override func prepareForReuse() {
        self.loadingSpinner.stopAnimating()
        self.likeCountLabel.text = "0"
        self.likeCountLabel.textColor = .lightGray
        self.seenCountLabel.text = "0"
        self.senderImageView.af_cancelImageRequest()
        self.senderImageView.image = UIImage(named: "single")
        self.senderNameLabel.text = "Loading..."
        self.timestampLabel.text = nil
        self.backgroundColor = UIColor.white
        self.isNewLabelHidden = true
    }

    var isNewLabelHidden: Bool = true {
        didSet {
            self.newLabelHeightConstraint.constant = self.isNewLabelHidden ? 0 : 30
        }
    }
}

class TailCell: SeparatorCell {
    var stream: Stream? {
        didSet {
            guard oldValue !== self.stream else {
                return
            }
            if let stream = oldValue {
                stream.changed.removeListener(self)
            }
            if let stream = self.stream {
                stream.changed.addListener(self, method: TailCell.updateStatus)
            }
            self.updateStatus()
        }
    }

    @IBOutlet weak var shareAnUpdateTopOffset: NSLayoutConstraint!
    @IBOutlet weak var statusLabel: UILabel!

    override func prepareForReuse() {
        self.updateStatus()
    }

    private func updateStatus() {
        guard let stream = self.stream, let participant = stream.nonIdleParticipant else {
            self.statusLabel.layer.removeAllAnimations()
            self.statusLabel.isHidden = true
            self.statusLabel.text = ""
            self.statusLabel.textColor = .lightGray
            self.shareAnUpdateTopOffset.constant = 8
            return
        }
        self.shareAnUpdateTopOffset.constant = 28
        let activity: String
        switch participant.activityStatus {
        case .playing:
            activity = "watching"
        case .recording:
            activity = "talking"
        default:
            activity = "active"
        }
        self.statusLabel.alpha = 0
        self.statusLabel.isHidden = false
        self.statusLabel.text = "\(participant.displayName) is \(activity)..."
        self.statusLabel.textColor = .fikaBlue
        UIView.animate(
            withDuration: 1,
            delay: 0,
            options: [.autoreverse, .repeat, .curveEaseOut],
            animations: { self.statusLabel.alpha = 1 })
    }
}
