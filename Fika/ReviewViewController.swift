import AVFoundation
import Crashlytics
import MobileCoreServices
import UIKit

protocol ReviewDelegate: class {
    func didFinishReviewing(reviewController: ReviewViewController, send: Bool)
}

class ReviewViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, ConversationImportDelegate {

    enum RecordingType: String {
        case broadcast, reply, share, unknown
    }

    @IBOutlet weak var addButton: UIButton!
    @IBOutlet weak var clipboardIndicatorView: UIView!
    @IBOutlet weak var closeButton: UIButton!
    @IBOutlet weak var sendButton: LoaderButton!
    @IBOutlet weak var sendTextButton: UIButton!
    @IBOutlet weak var recipientsTable: UITableView!
    @IBOutlet weak var saveButton: LoaderButton!
    @IBOutlet weak var selectRecipientsView: UIView!

    weak var delegate: ReviewDelegate?
    var attachments = [ChunkAttachment]()
    var containsPresentation = false
    var externalContentId: String?
    var presetStream: Stream?
    var recording: Recording!
    var type = RecordingType.unknown

    var selectedStreams = Set<Stream>() {
        didSet {
            self.updateSendLabel()
        }
    }

    var selectedParticipants = Set<Participant>() {
        didSet {
            self.updateSendLabel()
        }
    }

    var playerLayer: AVPlayerLayer? {
        didSet {
            if oldValue === self.playerLayer {
                return
            }
            if let layer = self.playerLayer {
                self.view.layer.insertSublayer(layer, at: 0)
            }
            if let layer = oldValue {
                layer.removeFromSuperlayer()
            }
        }
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override func viewDidLoad() {
        // Instant feedback for buttons within the tableView
        (self.recipientsTable.subviews.first as? UIScrollView)?.delaysContentTouches = false
        self.recipientsTable.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: self.recipientsTable.bounds.size.width, height: 0.01))

        let isBroadcast = self.presetStream == nil
        if isBroadcast {
            self.favorites = SettingsManager.favorites
            // TODO: Ensure this is the fully paginated set of streams.
            self.streams = StreamService.instance.streams.values.filter { !$0.isExternalShare }
            self.selectRecipientsView.isHidden = false
            self.recipientsTable.dataSource = self
            self.recipientsTable.delegate = self
            self.recipientsTable.allowsMultipleSelection = true
            self.recipientsTable.backgroundView = nil
            self.recipientsTable.backgroundColor = UIColor.clear
        } else {
            self.selectRecipientsView.isHidden = true
        }

        self.updateSendLabel()

        // Status indicator
        self.statusIndicatorView = StatusIndicatorView.create(container: self.view)

        // Setup player
        let player = AVPlayer(playerItem: AVPlayerItem(url: self.recording.fileURL))
        player.actionAtItemEnd = .none

        let layer = AVPlayerLayer(player: player)
        layer.frame = UIApplication.shared.keyWindow!.bounds
        self.playerLayer = layer

        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(ReviewViewController.tableLongPressed))
        self.recipientsTable.addGestureRecognizer(longPressRecognizer)

        // Loop player
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ReviewViewController.playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem)

        AppDelegate.applicationActiveStateChanged.addListener(self, method: ReviewViewController.handleApplicationActiveStateChanged)
    }

    override func viewWillLayoutSubviews() {
        self.playerLayer?.frame = UIApplication.shared.keyWindow!.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        self.playerLayer?.player?.play()
    }

    override func viewDidAppear(_ animated: Bool) {
        guard !self.hasAppeared else {
            // This is not the first time the view appeared, so just reload.
            if self.presetStream != nil {
                // No refresh necessary for reply mode.
                return
            }
            self.favorites = SettingsManager.favorites
            // TODO: Ensure this is the fully paginated set of streams.
            self.streams = StreamService.instance.streams.values.filter { !$0.isExternalShare }
            self.refreshStreamSections()
            return
        }
        self.hasAppeared = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.playerLayer?.player?.pause()
    }

    // MARK: - Actions

    @IBAction func addTapped(_ sender: Any) {
        self.showImportAlert()
    }

    @IBAction func closeTapped(_ sender: AnyObject) {
        if self.type != .share {
            // We don't count discarded shares since they're not unique content.
            Answers.logCustomEvent(withName: "Recording Discarded", customAttributes: [
                "Duration": self.recording.duration,
                "Presentation": self.containsPresentation ? "Yes" : "No",
                "Type": self.type.rawValue,
            ])
        }
        self.delegate?.didFinishReviewing(reviewController: self, send: false)
    }

    @IBAction func saveTapped(_ sender: Any) {
        // Ensure the video is uploaded if the user chooses to save it.
        _ = self.uploadToShared(recording)
        self.saveButton.isLoading = true
        self.getWatermarkedContent {
            guard let url = $0 else {
                self.saveButton.isLoading = false
                return
            }

            var attributes: [String: Any] = ["Duration": self.recording.duration]
            if let size = url.fileSize {
                attributes["FileSizeMB"] = Double(size) / 1024 / 1024
            }
            if self.type == .share {
                Answers.logCustomEvent(withName: "Share Saved", customAttributes: attributes)
            } else {
                attributes["Presentation"] = self.containsPresentation ? "Yes" : "No"
                attributes["Type"] = self.type.rawValue
                Answers.logCustomEvent(withName: "Recording Saved", customAttributes: attributes)
            }

            UISaveVideoAtPathToSavedPhotosAlbum(url.relativePath, self, #selector(ReviewViewController.handleDidSaveVideo), nil)
        }
    }

    @IBAction func sendTapped(_ sender: AnyObject) {
        let selectedCount: Int
        if self.presetStream != nil {
            selectedCount = 1
        } else {
            selectedCount = self.selectedParticipants.count + self.selectedStreams.count
        }
        guard selectedCount > 0 else {
            let alert = UIAlertController(title: "Oops!", message: "Select at least one person to send to.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
            self.present(alert, animated: true, completion: nil)
            return
        }

        var attributes: [String: Any] = [
            "Duration": self.recording.duration,
            "SelectedCount": selectedCount,
            ]
        if let size = self.recording.fileURL.fileSize {
            attributes["FileSizeMB"] = Double(size) / 1024 / 1024
        }
        if self.type == .share {
            Answers.logCustomEvent(withName: "Share Sent", customAttributes: attributes)
        } else {
            attributes["Presentation"] = self.containsPresentation ? "Yes" : "No"
            attributes["Type"] = self.type.rawValue
            Answers.logCustomEvent(withName: "Recording Sent", customAttributes: attributes)
        }
        Answers.logCustomEvent(withName: "Active User", customAttributes: ["Reason": "send"])

        self.delegate?.didFinishReviewing(reviewController: self, send: true)
    }

    @IBAction func shareTapped(_ sender: UIButton) {
        guard let url = self.getExternalContentURL(for: self.recording) else {
            return
        }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = share.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
        }
        self.present(share, animated: true)
    }

    @IBAction func copyTapped(_ sender: Any) {
        guard let url = self.getExternalContentURL(for: self.recording) else {
            return
        }
        self.recording.transcript
            .catch { _ in return [] }
            .then({
                let transcript = $0.map({ $0.text }).prefix(20).joined(separator: " ").replacingOccurrences(of: "\"", with: "&quot;")
                self.setClipboard(url, altText: transcript)
            })

        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [],
            animations: {
                self.clipboardIndicatorView.alpha = 1
                self.clipboardIndicatorView.transform = CGAffineTransform(translationX: 0, y: -24)
        },
            completion: { _ in
                UIView.animate(
                    withDuration: 0.2,
                    delay: 2,
                    options: [],
                    animations: {
                        self.clipboardIndicatorView.alpha = 0
                        self.clipboardIndicatorView.transform = CGAffineTransform(translationX: 0, y: -48)
                }
                )
        })
    }

    // MARK: - ConversationImportDelegate

    var conversationImportAnchorView: UIView {
        return self.addButton
    }

    func conversationImport(didCreateStream stream: Stream) {
        if let index = self.streams.index(where: { $0.id == stream.id }) {
            // We're already displaying this stream, so remove it to avoid dupe.
            self.streams.remove(at: index)
        } else {
            self.numStreamsShown += 1
        }
        self.streams.insert(stream, at: 0)
        self.selectedStreams.insert(stream)
        self.refreshStreamSections()
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section != 0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch indexPath.section {
        case 0:
            return
        case 1:
            // Favorites.
            let streamId = self.favorites[indexPath.row]
            guard let stream = StreamService.instance.streams[streamId] else {
                return
            }
            self.selectedStreams.insert(stream)
            if let index = self.streams.index(of: stream), index < self.numStreamsShown {
                self.recipientsTable.selectRow(at: IndexPath(row: index, section: 2), animated: false, scrollPosition: .none)
            }
        case 2:
            // Recent streams.
            if self.streams.isEmpty {
                self.showImportAlert()
                return
            } else if indexPath.row == self.numStreamsShown {
                self.recipientsTable.beginUpdates()
                let from = self.numStreamsShown
                let to = min(from + 5, self.streams.count)
                self.numStreamsShown = to
                if to == self.streams.count {
                    // The "View more recents..." row will be hidden.
                    self.recipientsTable.deleteRows(at: [IndexPath(row: from, section: 2)], with: .fade)
                }
                self.recipientsTable.insertRows(at: (from..<to).map({ IndexPath(row: $0, section: 2) }), with: .top)
                self.recipientsTable.endUpdates()
                self.refreshSelections()
                return
            }
            let stream = self.streams[indexPath.row]
            self.selectedStreams.insert(stream)
            if let index = self.favorites.index(of: stream.id) {
                self.recipientsTable.selectRow(at: IndexPath(row: index, section: 1), animated: false, scrollPosition: .none)
            }
        default:
            // Alphabetized person.
            guard let participant = self.indexAccountsMap[self.indexTitles[indexPath.section]]?[indexPath.row] else {
                return
            }
            self.selectedParticipants.insert(participant)
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        switch indexPath.section {
        case 0:
            return
        case 1:
            // Favorites.
            let streamId = self.favorites[indexPath.row]
            guard let stream = StreamService.instance.streams[streamId] else {
                return
            }
            if let index = self.streams.index(of: stream), index < self.numStreamsShown {
                self.recipientsTable.deselectRow(at: IndexPath(row: index, section: 2), animated: false)
            }
            self.selectedStreams.remove(stream)
        case 2:
            guard self.streams.count > 0 else {
                return
            }
            // Recent streams.
            let stream = self.streams[indexPath.row]
            if let index = self.favorites.index(of: stream.id) {
                self.recipientsTable.deselectRow(at: IndexPath(row: index, section: 1), animated: false)
            }
            self.selectedStreams.remove(stream)
        default:
            // Alphabetized people.
            guard let participant = self.indexAccountsMap[self.indexTitles[indexPath.section]]?[indexPath.row] else {
                return
            }
            self.selectedParticipants.remove(participant)
        }
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return self.indexTitles.count
    }

    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        return self.indexTitles
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return 2
        case 1:
            return self.favorites.count
        case 2:
            if self.streams.count > self.numStreamsShown {
                return self.numStreamsShown + 1
            } else if self.streams.isEmpty {
                return 1
            } else {
                return self.streams.count
            }
        default:
            return self.indexAccountsMap[self.indexTitles[section]]?.count ?? 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            return tableView.dequeueReusableCell(withIdentifier: indexPath.row == 0 ? "ShareCell" : "CopyCell", for: indexPath)
        case 1:
            // Favorites.
            let cell = tableView.dequeueReusableCell(withIdentifier: "RecipientCell") as! RecipientCell
            let streamId = self.favorites[indexPath.row]
            guard let stream = StreamService.instance.streams[streamId] else {
                // TODO: Error!
                return cell
            }
            cell.decorate(stream: stream)
            return cell
        case 2:
            // Recent streams.
            if self.streams.isEmpty {
                return tableView.dequeueReusableCell(withIdentifier: "EmptyCell", for: indexPath)
            } else if indexPath.row == self.numStreamsShown {
                return tableView.dequeueReusableCell(withIdentifier: "MoreCell", for: indexPath)
            }
            let stream = self.streams[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "RecipientCell") as! RecipientCell
            cell.decorate(stream: stream, badge: self.favorites.contains(stream.id) ? "🌟" : nil)
            return cell
        default:
            // Alphabetized people.
            let cell = tableView.dequeueReusableCell(withIdentifier: "RecipientCell") as! RecipientCell
            let participant = self.indexAccountsMap[self.indexTitles[indexPath.section]]![indexPath.row]
            cell.decorate(participant: participant)
            return cell
        }
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch section {
        case 0:
            return 8
        case 1:
            return self.favorites.count > 0 ? 48 : 0
        default:
            return 48
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section != 0 && (section != 1 || self.favorites.count > 0) else {
            return nil
        }

        // Containing view for the section header label.
        let headerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.frame.width, height: 48))
        headerView.backgroundColor = UIColor.clear

        // Create section label with header text.
        let sectionLabel = UILabel()
        sectionLabel.font = UIFont.systemFont(ofSize: 14, weight: UIFontWeightBold)
        sectionLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        switch section {
        case 1:
            sectionLabel.text = "FAVORITES"
        case 2:
            sectionLabel.text = "RECENTS"
        default:
            sectionLabel.text = self.indexTitles[section]
        }
        sectionLabel.textAlignment = .center
        sectionLabel.sizeToFit()
        sectionLabel.frame.origin = CGPoint(x: 16, y: 18)
        headerView.addSubview(sectionLabel)

        let separator = CALayer()
        separator.backgroundColor = UIColor.white.withAlphaComponent(0.2).cgColor
        separator.frame = CGRect(x: 16, y: headerView.frame.height - 0.5, width: headerView.bounds.width - 32, height: 0.5)
        headerView.layer.insertSublayer(separator, at: 0)
        return headerView
    }

    // MARK: - Private

    private var exportedContentURL: URL?
    private var hasAppeared = false
    private var importAlert: ConversationImportAlert?
    private var indexTitles = [String]()
    private var indexAccountsMap = [String: [Participant]]()
    private var numStreamsShown = 4
    private var statusIndicatorView: StatusIndicatorView!

    private var favorites = [Int64]()

    private var streams = [Stream]() {
        didSet {
            self.indexAccountsMap.removeAll()

            let participants = Set<Participant>(self.streams.flatMap { $0.otherParticipants })
            participants.forEach { participant in
                guard let firstCharacter = participant.displayName.characters.first else {
                    return
                }
                let firstLetter = String(firstCharacter).localizedUppercase
                if self.indexAccountsMap[firstLetter] == nil {
                    self.indexAccountsMap[firstLetter] = [participant]
                } else {
                    self.indexAccountsMap[firstLetter]!.append(participant)
                }
            }

            // Track section index titles as a sorted array.
            self.indexTitles = ["", "★", ""]
            self.indexTitles.append(contentsOf: self.indexAccountsMap.keys.sorted(by: { $0 < $1 }))
            self.recipientsTable.reloadData()
        }
    }

    private func getExternalContentURL(for recording: Recording) -> URL? {
        return SettingsManager.getExternalContentURL(for: self.uploadToShared(recording))
    }

    private func getWatermarkedContent(callback: @escaping (URL?) -> ()) {
        // If exported content already exists, share immediately
        if let url = self.exportedContentURL {
            callback(url)
            return
        }

        let url = self.recording.fileURL
        let asset = AVAsset(url: url)
        guard let audio = asset.tracks(withMediaType: AVMediaTypeAudio).first,
            let video = asset.tracks(withMediaType: AVMediaTypeVideo).first  else {
                callback(url)
                return
        }

        let mixComposition = AVMutableComposition()
        let videoTrack = mixComposition.addMutableTrack(withMediaType: AVMediaTypeVideo, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = mixComposition.addMutableTrack(withMediaType: AVMediaTypeAudio, preferredTrackID: kCMPersistentTrackID_Invalid)

        do {
            try videoTrack.insertTimeRange(CMTimeRange(start: kCMTimeZero, duration: asset.duration), of: video, at: kCMTimeZero)
            try audioTrack.insertTimeRange(CMTimeRange(start: kCMTimeZero, duration: asset.duration), of: audio, at: kCMTimeZero)
        } catch {
            NSLog("WARNING: Failure when inserting audio/video tracks")
            return
        }

        let imageLayer = CALayer()
        let image = UIImage(named: "madeWithFika")!
        imageLayer.contents = image.cgImage
        let imageSize = CGSize(width: image.size.width * 2, height: image.size.height * 2)
        let videoSize = video.naturalSize
        imageLayer.frame = CGRect(x: videoSize.width - imageSize.width - 30, y: 30, width: imageSize.width, height: imageSize.height)
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(x: 0, y: 0, width: videoSize.width, height: videoSize.height);
        videoLayer.frame = CGRect(x: 0, y: 0, width: videoSize.width, height: videoSize.height);
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(imageLayer)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTimeMake(1, 30)
        videoComposition.renderSize = videoSize
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: kCMTimeZero, duration: mixComposition.duration)
        instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)]
        videoComposition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) else {
            return
        }
        export.videoComposition = videoComposition

        let exportPath = NSTemporaryDirectory().appending("export.mp4")
        let exportURL = URL(fileURLWithPath: exportPath)
        if FileManager.default.fileExists(atPath: exportPath) {
            try? FileManager.default.removeItem(atPath: exportPath)
        }

        export.outputFileType = AVFileTypeMPEG4
        export.outputURL = exportURL
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
            self.exportedContentURL = exportURL
            DispatchQueue.main.async {
                callback(exportURL)
            }
        }
    }

    private func handleApplicationActiveStateChanged(active: Bool) {
        // Resume playback of any playing review video.
        self.playerLayer?.player?.play()
    }

    private dynamic func handleDidSaveVideo(videoPath: String, error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        self.saveButton.isLoading = false
    }

    private dynamic func playerItemDidReachEnd(_ notification: NSNotification) {
        if let item = notification.object as? AVPlayerItem {
            item.seek(to: kCMTimeZero)
        }
    }

    private func refreshSelections() {
        self.selectedStreams.forEach {
            if let index = self.favorites.index(of: $0.id) {
                self.recipientsTable.selectRow(at: IndexPath(row: index, section: 1), animated: false, scrollPosition: .none)
            }
            if let index = self.streams.index(of: $0), index < self.numStreamsShown {
                self.recipientsTable.selectRow(at: IndexPath(row: index, section: 2), animated: false, scrollPosition: .none)
            }
        }
    }

    private func refreshStreamSections() {
        self.recipientsTable.reloadSections(IndexSet(integer: 1), with: .none)
        self.recipientsTable.reloadSections(IndexSet(integer: 2), with: .none)
        self.refreshSelections()
    }

    private func setClipboard(_ url: URL, altText: String = "") {
        let urlText = url.absoluteString
        let html = "<a href=\"\(urlText)\"><img alt=\"\(altText)\" src=\"\(urlText).gif\" width=\"160\" height=\"160\"></a><br>Made with <a href=\"\(urlText)\">fika.io</a>"
        let resource = [
            "WebResourceData": html.data(using: .utf8)!,
            "WebResourceFrameName":  "",
            "WebResourceMIMEType" : "text/html",
            "WebResourceTextEncodingName" : "UTF-8",
            "WebResourceURL" : urlText,
            ] as [String: Any]
        let item = [
            kUTTypeText as String: urlText,
            kUTTypeURL as String: url,
            "Apple Web Archive pasteboard type": ["WebMainResource": resource],
            ] as [String: Any]
        UIPasteboard.general.setItems([item], options: [:])
    }

    private func showImportAlert() {
        let alert = ConversationImportAlert(title: nil, message: nil, importActions: [.invite, .createStream, .connectFromSlack], otherActions: [], owner: self, delegate: self)
        alert.show()
        // TODO: Set this to nil when the alert flow is completed.
        self.importAlert = alert
    }

    private dynamic func tableLongPressed(recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self.recipientsTable)
        guard
            recognizer.state == .began,
            let indexPath = self.recipientsTable.indexPathForRow(at: point)
            else { return }
        switch indexPath.section {
        case 1:
            // Favorites.
            self.favorites = SettingsManager.toggleFavorite(streamId: self.favorites[indexPath.row])
            self.refreshStreamSections()
        case 2:
            // Recent streams.
            guard !self.streams.isEmpty && indexPath.row < self.numStreamsShown else {
                return
            }
            let stream = self.streams[indexPath.row]
            guard !stream.isInvitation else {
                return
            }
            self.favorites = SettingsManager.toggleFavorite(streamId: stream.id)
            self.refreshStreamSections()
        default:
            return
        }
    }

    private func updateSendLabel() {
        let label, icon: String
        if let stream = self.presetStream {
            label = stream.title
            icon = "send"
            self.sendButton.backgroundColor = .fikaBlue
        } else {
            let selectionCount = self.selectedStreams.count + self.selectedParticipants.count
            self.sendButton.backgroundColor = selectionCount == 0 ? .lightGray : .fikaBlue
            label = "Send (\(selectionCount))"
            icon = "send"
        }
        self.sendTextButton.setTitle(label, for: .normal)
        self.sendButton.setTitle(icon, for: .normal)
    }

    /// If there is no external content id, generate one and kick off an upload.
    private func uploadToShared(_ recording: Recording) -> String {
        if let id = self.externalContentId {
            return id
        }
        let externalContentId = String.randomBase62(of: 21)
        // Send the chunk to the shared stream.
        let getShareStream = Promise<Stream> { resolve, reject in
            if let stream = StreamService.instance.streams.values.first(where: { $0.isExternalShare }) {
                resolve(stream)
            } else {
                StreamService.instance.getOrCreateStream(participants: [], showInRecents: true, title: Stream.externalShareTitle) { stream, error in
                    guard let stream = stream else {
                        reject(error ?? NSError())
                        return
                    }
                    resolve(stream)
                }
            }
        }
        getShareStream.then { stream in
            recording.transcript
                .catch { _ in return [] }
                .then({
                    let chunk = Intent.Chunk(
                        url: recording.fileURL,
                        attachments: self.attachments,
                        duration: Int(recording.duration * 1000),
                        externalContentId: externalContentId,
                        textSegments: $0)
                    StreamService.instance.sendChunk(streamId: stream.id, chunk: chunk, persist: true,
                                                     showInRecents: true, duplicate: true)
                })
        }
        self.externalContentId = externalContentId
        return externalContentId
    }
}

class RecipientCell: UITableViewCell {
    @IBOutlet weak var streamTitleLabel: UILabel!
    @IBOutlet weak var streamSubtextLabel: UILabel!
    @IBOutlet weak var selectionToggleLabel: UILabel!

    let highlightColor = UIColor.black.withAlphaComponent(0.5)

    func decorate(participant: Participant) {
        self.streamTitleLabel.text = participant.displayName
        if let time = participant.localTime {
            self.streamSubtextLabel.isHidden = false
            self.streamSubtextLabel.text = "\(time.formattedTime) local time"
        } else if let id = participant.commonTeams.first(where: { $0.service == "slack" }) {
            self.streamSubtextLabel.isHidden = false
            self.streamSubtextLabel.text = "\(id.teamName) (Slack)"
        } else if !participant.isActive {
            self.streamSubtextLabel.isHidden = false
            self.streamSubtextLabel.text = "Invited"
        }
    }

    func decorate(stream: Stream, badge: String? = nil) {
        if let badge = badge {
            self.streamTitleLabel.text = "\(stream.title) \(badge)"
        } else {
            self.streamTitleLabel.text = stream.title
        }
        if stream.isGroup {
            self.streamTitleLabel.text?.append(" (\(stream.otherParticipants.count + 1))")
        }
        // Set the subtext for the stream based on best available information.
        if stream.isDuo, let time = stream.otherParticipants[0].localTime {
            self.streamSubtextLabel.isHidden = false
            self.streamSubtextLabel.text = "\(time.formattedTime) local time"
        } else if
            let id = stream.serviceContentId, id.service == "slack",
            let services = BackendClient.instance.session?.services,
            let team = services.first(where: { $0.team?.id == id.team })?.team
        {
            // TODO: Support more than Slack.
            self.streamSubtextLabel.isHidden = false
            self.streamSubtextLabel.text = "\(team.name) (Slack)"
        } else if stream.isInvitation {
            self.streamSubtextLabel.isHidden = false
            self.streamSubtextLabel.text = "Invited (will be sent by email)"
        } else if let _ = stream.chunks.last {
            // TODO: Decide if we want to show last interaction instead of nothing.
        }
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        if highlighted || self.isSelected {
            self.backgroundColor = self.highlightColor
        } else {
            self.backgroundColor = .clear
        }
        super.setHighlighted(highlighted, animated: animated)
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        if selected {
            self.selectionToggleLabel.pulse()
            self.selectionToggleLabel.text = "radio_button_checked"
            self.backgroundColor = self.highlightColor
        } else {
            self.backgroundColor = .clear
            self.selectionToggleLabel.text = "radio_button_unchecked"
        }
        super.setSelected(selected, animated: animated)
    }

    override func prepareForReuse() {
        self.streamTitleLabel.text = nil
        self.streamSubtextLabel.text = nil
        self.streamSubtextLabel.isHidden = true
    }
}
