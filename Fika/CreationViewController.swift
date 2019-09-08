import AVFoundation
import Crashlytics
import pop
import Speech
import UIKit

class CreationViewController:
    UIViewController,
    ActionBarDelegate,
    PagerPage,
    PermissionsDelegate,
    PresentationViewDelegate,
    RecordBarDelegate,
    ReviewDelegate,
    UIImagePickerControllerDelegate,
    UINavigationControllerDelegate,
    UITextFieldDelegate {

    // MARK: - Properties

    var clipboardURL: URL? = nil
    private(set) var isPresenting = false
    var pager: Pager?
    var presetStream: Stream?

    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    // MARK: - Outlets

    @IBOutlet weak var closeButton: CameraControlButton!
    @IBOutlet weak var feedButton: LoaderButton!
    @IBOutlet weak var navigationHeaderView: UIView!
    @IBOutlet weak var sentLabel: UILabel!
    @IBOutlet weak var streamTitleLabel: UILabel!

    // TODO: Figure out a better way to pass this information.
    func present(url: URL) {
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            switch url.pathExtension.lowercased() {
            case "avi", "mov", "mp4":
                self.showVideoView()
                self.videoView.loadVideo(url: url)
            default:
                self.presentationView.attachment = .document(url)
                self.showPresentation()
            }
        } else {
            self.presentationView.attachment = .webPage(url)
            self.showPresentation()
        }
    }

    // MARK: - UIViewController

    override func viewDidLoad() {
        self.feedButton.set(shadowX: 0, y: 1, radius: 2, color: .black, opacity: 0.3)
        self.streamTitleLabel.set(shadowX: 0, y: 1, radius: 2, color: .black, opacity: 0.3)

        // Set up the blur effect for when app goes into background.
        self.screenCurtain = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        self.screenCurtain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.screenCurtain.frame = self.view.bounds
        self.screenCurtain.isUserInteractionEnabled = false
        self.screenCurtain.alpha = 0

        // Set up the camera view that renders the camera input.
        self.cameraView = CameraView(frame: .zero, preview: Recorder.instance.previewLayer)

        // Pinch to zoom.
        self.cameraView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(CreationViewController.cameraViewPinched)))
        // Tap to focus. Or, in presentation mode, maximize the camera view.
        self.cameraView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(CreationViewController.cameraViewTapped)))
        // Double tap to switch camera direction.
        let doubleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(CreationViewController.cameraViewDoubleTapped))
        doubleTapRecognizer.numberOfTapsRequired = 2
        self.cameraView.addGestureRecognizer(doubleTapRecognizer)

        // Hide the reply view when swiping down.
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(CreationViewController.viewSwipedDown))
        swipeDown.direction = .down
        self.view.addGestureRecognizer(swipeDown)

        // Set up the record bar that contains all the actions at the bottom of the screen.
        self.recordBar = RecordBar(frame: CGRect(x: 0, y: self.view.bounds.height - 100, width: self.view.bounds.width, height: 100))
        self.recordBar.autoresizingMask = [.flexibleTopMargin, .flexibleWidth]
        self.recordBar.delegate = self

        // Set up a secondary bar for additional actions at the top of the screen.
        self.secondaryBar = ActionBar(frame: CGRect(x: 8, y: 20, width: 100, height: 40))
        self.secondaryBar.alignment = .leading
        self.secondaryBar.buttonSize = CGSize(width: 40, height: 40)
        self.secondaryBar.delegate = self

        self.markerView.isHidden = true
        self.videoView.isHidden = true

        // Gradient for top and bottom controls
        self.gradientView.isUserInteractionEnabled = false

        // Handle requests for playing video.
        self.presentationView.delegate = self

        // Order all the views correctly in the hierarchy.
        // TODO: Make this cleaner.
        self.view.insertSubview(self.presentationView, at: 0)
        self.view.insertSubview(self.cameraView, at: 1)
        self.view.insertSubview(self.videoView, at: 2)
        self.view.insertSubview(self.markerView, at: 3)
        self.view.insertSubview(self.screenCurtain, at: 4)
        self.view.insertSubview(self.gradientView, at: 5)
        self.view.insertSubview(self.navigationHeaderView, at: 6)
        self.view.insertSubview(self.recordBar, at: 7)
        self.view.insertSubview(self.secondaryBar, at: 8)

        // Show permissions view if any of the permissions are not granted.
        if !PermissionsView.hasPermissions {
            let view = PermissionsView.create(frame: self.view.bounds, delegate: self)
            self.permissionsView = view
            self.view.addSubview(view)
            self.pager?.isPagingEnabled = false
            return
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        coordinator.animateAlongsideTransition(in: self.view, animation: { _ in
            self.updateOrientation()
        }, completion: nil)
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewWillAppear(_ animated: Bool) {
        self.updateOrientation()
        self.cameraView.layoutPreview()
        self.refresh()

        // The recorder's configuration may have changed elsewhere.
        self.screenCurtain.isHidden = true
        self.refreshActions()
        self.showRecorderPreview()

        AppDelegate.applicationActiveStateChanged.addListener(self, method: CreationViewController.handleApplicationActiveStateChanged)
        StreamService.instance.unplayedCountChanged.addListener(self, method: CreationViewController.refresh)
        Recorder.instance.recorderUnavailable.addListener(self, method: CreationViewController.handleRecorderUnavailable)
    }

    override func viewDidDisappear(_ animated: Bool) {
        AppDelegate.applicationActiveStateChanged.removeListener(self)
        StreamService.instance.unplayedCountChanged.removeListener(self)
        Recorder.instance.recorderUnavailable.removeListener(self)
    }

    @IBAction func closeTapped(_ sender: Any) {
        self.dismiss(animated: true, completion: nil)
    }

    @IBAction func feedTapped(_ sender: AnyObject) {
        self.pager?.pageTo(.feed)
    }

    // MARK: - ActionBarDelegate

    func actionBar(_ actionBar: ActionBar, requestingAction action: ActionBar.Action) {
        self.handleAction(action)
    }

    func actionBar(_ actionBar: ActionBar, action: ActionBar.Action, translation: CGPoint, state: UIGestureRecognizerState) {
    }

    // MARK: - PagerPage

    func didPage(swiped: Bool) {
    }

    // MARK: - PresentationViewDelegate

    func presentationView(_ view: PresentationView, requestingToPlay mediaURL: URL, with info: MediaRequestInfo) {
        self.showVideoView()
        self.videoView.loadVideo(url: mediaURL)
        self.mediaRequestInfo = info
        if Recorder.instance.state == .recording {
            self.updateAttachment()
        }
    }

    // MARK: - RecordBarDelegate

    func audioLevel(for recordBar: RecordBar) -> Float {
        let level = Recorder.instance.audioLevel
        return 1 + 0.1 * level / pow(level, 0.7)
    }

    func recordBar(_ recordBar: RecordBar, action: ActionBar.Action, translation: CGPoint, state: UIGestureRecognizerState) {
        switch action {
        case .markerOff:
            let x = (SettingsManager.markerHue - Float(translation.y / 1.5)).truncatingRemainder(dividingBy: 360)
            let hue = x < 0 ? x + 360 : x
            if state == .ended {
                SettingsManager.markerHue = hue
            }
            if let button = recordBar.button(for: .markerOff) {
                let color = UIColor(hue: CGFloat(hue / 360), saturation: 1, brightness: 1, alpha: 1)
                button.setTitleColor(color, for: .normal)
            }
        default:
            return
        }
    }

    func recordBar(_ recordBar: RecordBar, requestingAction action: ActionBar.Action) {
        self.handleAction(action)
    }

    func recordBar(_ recordBar: RecordBar, requestingZoom magnitude: Float) {
        Recorder.instance.zoom(to: CGFloat(1 + magnitude * 14))
    }

    // MARK: - ReviewDelegate

    func didFinishReviewing(reviewController: ReviewViewController, send: Bool) {
        reviewController.dismiss(animated: false) { _ in
            guard send else {
                return
            }
            self.sentLabel.isHidden = false
            self.sentLabel.pulse()
            UIView.animate(withDuration: 0.3, delay: 1, options: [], animations: {
                self.sentLabel.alpha = 0
            }) { _ in
                self.sentLabel.isHidden = true
                self.sentLabel.alpha = 1
            }
        }
        guard send else {
            return
        }

        // Dimiss immediately if presented for a stream
        if self.presetStream != nil {
            self.dismiss(animated: true, completion: nil)
        }

        guard let recording = reviewController.recording else {
            return
        }

        // TODO: Show a loader.
        recording.transcript
            .catch({
                // TODO: Display alert if transcription was unsuccessful?
                NSLog("%@", "WARNING: Failed to get a transcript: \($0)")
                return []
            })
            .then({
                let chunk = Intent.Chunk(
                    url: recording.fileURL,
                    attachments: reviewController.attachments,
                    duration: Int(recording.duration * 1000),
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
            })
    }

    // MARK: - PermissionDelegate

    func didReceivePermissions() {
        UIView.animate(withDuration: 0.3, animations: {
            self.permissionsView?.alpha = 0
        }) { _ in
            self.permissionsView?.removeFromSuperview()
            self.pager?.isPagingEnabled = true
        }
        self.showRecorderPreview()

        let tutorialAlert = self.storyboard!.instantiateViewController(withIdentifier: "Tutorial")
        tutorialAlert.modalPresentationStyle = .overFullScreen
        tutorialAlert.modalTransitionStyle = .crossDissolve
        self.present(tutorialAlert, animated: true, completion: nil)
    }

    // MARK: - UIImagePickerControllerDelegate

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : Any]) {
        // Picker is always portrait, so laying out views before it is disimissed causes bugs in landscape mode.
        picker.dismiss(animated: true) {
            guard let image = info[UIImagePickerControllerOriginalImage] as? UIImage else {
                return
            }
            self.presentationView.attachment = .image(image)
            self.showPresentation()
            self.refreshActions()
        }
    }

    // MARK: - UITextFieldDelegate

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // Auto-select everything in the web page alert box text field.
        textField.selectAll(nil)
    }

    // MARK: - Private

    private let markerView = MarkerView(frame: UIScreen.main.bounds)
    private let presentationView = PresentationView(frame: UIScreen.main.bounds)
    private let videoView = VideoView(frame: .zero)

    private var attachment: ChunkAttachment?
    private var cameraView: CameraView!
    private var gradientView = GradientView()
    private var lastRecordingContainsPresentation = false
    private var mediaRequestInfo: MediaRequestInfo?
    private var permissionsView: PermissionsView?
    private var previousPinchScale = CGFloat(1)
    private var recordBar: RecordBar!
    private var screenCurtain: UIView!
    private var secondaryBar: ActionBar!

    private dynamic func cameraViewPinched(recognizer: UIPinchGestureRecognizer) {
        // TODO: Also disallow this while long pressing?
        guard !self.cameraView.isMinimized, let zoom = Recorder.instance.currentZoom else {
            return
        }
        switch recognizer.state {
        case .began:
            self.previousPinchScale = zoom
        case .changed:
            Recorder.instance.zoom(to: self.previousPinchScale * recognizer.scale)
        default:
            break
        }
    }

    private dynamic func cameraViewDoubleTapped(recognizer: UITapGestureRecognizer) {
        SettingsManager.preferFrontCamera = !SettingsManager.preferFrontCamera
        if Recorder.instance.configuration != .audioOnly {
            Recorder.instance.configuration = SettingsManager.preferFrontCamera ? .frontCamera : .backCamera
        }
        self.refreshActions()
    }

    private dynamic func cameraViewTapped(recognizer: UITapGestureRecognizer) {
        guard !self.isPresenting else {
            return
        }
        // TODO: Display an indicator in the UI for where the user tapped.
        let point = recognizer.location(in: self.view)
        Recorder.instance.focus(point: self.cameraView.focusPoint(for: point))
    }

    private func enterAudioMode() {
        Recorder.instance.configuration = .audioOnly
        self.cameraView.isHidden = true
        self.presentationView.showAudioVisualizer()
    }

    private func enterVideoMode() {
        Recorder.instance.configuration = SettingsManager.preferFrontCamera ? .frontCamera : .backCamera
        self.cameraView.isHidden = false
        self.presentationView.hideAudioVisualizer()
    }

    private func handleAction(_ action: ActionBar.Action) {
        Answers.logCustomEvent(withName: "Camera View Action", customAttributes: [
            "Action": action.rawValue,
            "Recording": Recorder.instance.state == .recording ? "Yes" : "No",
        ])
        switch action {
        case .back:
            self.presentationView.goBack()
        case .beginRecording:
            self.startRecording()
        case .clearImage, .clearWeb:
            self.hidePresentation()
        case .endRecording:
            self.stopRecording()
        case .markerOn:
            self.markerView.isHidden = false
        case .markerOff:
            self.markerView.isHidden = true
        case .presentImage:
            self.presentationView.attachment = .none
            // TODO: Custom picker.
            let picker = UIImagePickerController()
            picker.delegate = self
            self.present(picker, animated: true, completion: nil)
        case .presentWeb:
            self.presentationView.attachment = .none
            // Clipboard link (except fika.io links).
            // TODO: Attempt to prefetch clipboard somewhere to avoid lag?
            if let url = UIPasteboard.general.url, url.host != "watch.fika.io" {
                self.clipboardURL = url
            }
            self.showWebPageSheet()
        case .text:
            // Ensure that marker mode is on.
            self.markerView.isHidden = false
            self.refreshActions()
            self.markerView.addText()
        case .useFrontCamera:
            if Recorder.instance.configuration != .audioOnly {
                Recorder.instance.configuration = .frontCamera
            }
            SettingsManager.preferFrontCamera = true
        case .useBackCamera:
            if Recorder.instance.configuration != .audioOnly {
                Recorder.instance.configuration = .backCamera
            }
            SettingsManager.preferFrontCamera = false
        case .videoOff:
            self.enterAudioMode()
        case .videoOn:
            self.enterVideoMode()
        }
        self.refreshActions()
    }

    private func refresh() {
        // Set a background color if there are other streams with unplayed content.
        let unplayedStreamCount = StreamService.instance.streams.values.reduce(0) { $0 + ($1.isUnplayed ? 1 : 0) }
        if unplayedStreamCount > 0 {
            self.feedButton.backgroundColor = .fikaRed
            self.feedButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: UIFontWeightSemibold)
            self.feedButton.setTitle(unplayedStreamCount.description, for: .normal)
        } else {
            self.feedButton.backgroundColor = .clear
            self.feedButton.titleLabel?.font = UIFont.materialFont(ofSize: 30)
            self.feedButton.setTitle("history", for: .normal)
        }

        self.navigationHeaderView.isHidden = self.isPresenting

        if let stream = self.presetStream {
            self.closeButton.isHidden = false
            self.feedButton.isHidden = true
            self.streamTitleLabel.text = stream.title
        } else {
            self.closeButton.isHidden = true
            self.feedButton.isHidden = false
            self.streamTitleLabel.text = nil
        }

        guard PermissionsView.hasPermissions else {
            return
        }

        if Recorder.instance.configuration == .audioOnly {
            self.enterAudioMode()
        } else {
            self.enterVideoMode()
        }
    }

    private func refreshActions() {
        switch self.presentationView.attachment {
        case .none:
            self.recordBar.before.actions = [.presentImage, .presentWeb]
        case .document, .webPage:
            self.recordBar.before.actions = [.presentImage, .clearWeb]
        case .image:
            self.recordBar.before.actions = [.clearImage, .presentWeb]
        }

        self.recordBar.after.actions = [self.markerView.isHidden ? .markerOn : .markerOff, .text]

        var actions: [ActionBar.Action] = []
        if case .webPage = self.presentationView.attachment {
            actions.append(.back)
        }
        let isCameraOff = Recorder.instance.configuration == .audioOnly
        actions.append(isCameraOff ? .videoOn : .videoOff)
        actions.append(SettingsManager.preferFrontCamera ? .useBackCamera : .useFrontCamera)
        self.secondaryBar.actions = actions

        // Dim the front/back camera action when camera is off.
        let alpha: CGFloat = isCameraOff ? 0.5 : 1.0
        self.secondaryBar.button(for: .useBackCamera)?.alpha = alpha
        self.secondaryBar.button(for: .useFrontCamera)?.alpha = alpha

        if let button = self.recordBar.button(for: .markerOff) {
            button.setTitleColor(SettingsManager.markerColor, for: .normal)
        }
    }

    private dynamic func hidePresentation() {
        guard self.isPresenting else { return }
        self.isPresenting = false
        self.cameraView.maximize()
        self.markerView.isHidden = true
        self.navigationHeaderView.showAnimated()
        self.presentationView.attachment = .none
        self.refreshActions()
    }

    private dynamic func showPresentation() {
        guard !self.isPresenting else {
            return
        }
        self.isPresenting = true
        self.cameraView.minimize()
        self.navigationHeaderView.hideAnimated()
        self.markerView.isHidden = true
        self.refreshActions()
        if Recorder.instance.state == .recording {
            self.updateAttachment()
        }
    }

    private func hideVideoView() {
        guard !self.videoView.isHidden else {
            return
        }

        self.mediaRequestInfo = nil

        let videoAnim = POPBasicAnimation(propertyNamed: kPOPViewFrame)!
        videoAnim.duration = 0.2
        videoAnim.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
        let from = self.videoView.frame
        videoAnim.fromValue = from
        videoAnim.toValue = CGRect(origin: CGPoint(x: from.origin.x, y: UIScreen.main.bounds.height), size: from.size)
        videoAnim.completionBlock = { (_, _) in
            self.videoView.isHidden = true
            self.videoView.clearVideo()
        }
        self.videoView.pop_add(videoAnim, forKey: "frame")

        if !self.cameraView.isMinimized {
            self.cameraView.maximize()
        }

        let presoAnim = POPBasicAnimation(propertyNamed: kPOPViewFrame)!
        presoAnim.duration = 0.2
        presoAnim.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
        presoAnim.fromValue = self.presentationView.frame
        presoAnim.toValue = UIScreen.main.bounds
        self.presentationView.pop_add(presoAnim, forKey: "frame")
    }

    private func showVideoView() {
        guard self.videoView.isHidden else {
            return
        }

        if self.isPresenting {
            self.isPresenting = false
            self.navigationHeaderView.showAnimated()
            self.presentationView.attachment = .none
        }

        self.updateVideoFrames(enter: true)
        self.videoView.isHidden = false
        self.refreshActions()
    }

    private func showRecorderPreview() {
        // Show permissions view if any of the permissions are not granted.
        guard PermissionsView.hasPermissions else {
            return
        }
        if Recorder.instance.state == .idle {
            Recorder.instance.startPreviewing()
        }
    }

    private func showWebPageAlert() {
        let alert = UIAlertController(title: "Search", message: nil, preferredStyle: .alert)
        alert.addTextField(configurationHandler: { textField in
            textField.keyboardType = .webSearch
            textField.placeholder = "Search or enter website name"
            textField.returnKeyType = .go
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Go", style: .default, handler: { _ in
            guard let text = alert.textFields?.first?.text, !text.isEmpty else {
                return
            }
            var address: URLComponents
            if text.contains(".") {
                guard let c = URLComponents(string: text.contains("://") ? text : "https://\(text)") else {
                    return
                }
                address = c
            } else {
                // Turn the text into a query if it doesn't contain a period.
                address = URLComponents(string: "https://google.com/search")!
                address.queryItems = [URLQueryItem(name: "q", value: text)]
            }
            guard let url = address.url else {
                return
            }
            self.presentationView.attachment = .webPage(url)
            self.showPresentation()
            self.refreshActions()
        }))
        alert.textFields?.first?.delegate = self
        self.present(alert, animated: true)
    }

    private func showWebPageSheet() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if let url = self.clipboardURL {
            sheet.addAction(UIAlertAction(title: "🔗 \(url.absoluteString)", style: .default) { _ in
                self.presentationView.attachment = .webPage(url)
                self.showPresentation()
                self.refreshActions()
            })
        }
        // From team collaboration to news service 🙃
        sheet.addAction(UIAlertAction(title: "Flipboard", style: .default) { _ in
            self.presentationView.attachment = .webPage(URL(string: "https://flipboard.com/")!)
            self.showPresentation()
            self.refreshActions()
        })
        sheet.addAction(UIAlertAction(title: "Pocket", style: .default) { _ in
            self.presentationView.attachment = .webPage(URL(string: "https://getpocket.com/")!)
            self.showPresentation()
            self.refreshActions()
        })
        sheet.addAction(UIAlertAction(title: "Google News", style: .default) { _ in
            self.presentationView.attachment = .webPage(URL(string: "https://news.google.com/")!)
            self.showPresentation()
            self.refreshActions()
        })
        /*
        sheet.addAction(UIAlertAction(title: "Box", style: .default) { _ in
            self.presentationView.attachment = .webPage(URL(string: "https://account.box.com/login")!)
            self.showPresentation()
            self.refreshActions()
        })
        sheet.addAction(UIAlertAction(title: "Dropbox", style: .default) { _ in
            self.presentationView.attachment = .webPage(URL(string: "https://www.dropbox.com/login")!)
            self.showPresentation()
            self.refreshActions()
        })
        sheet.addAction(UIAlertAction(title: "Google Drive", style: .default) { _ in
            self.presentationView.attachment = .webPage(URL(string: "https://accounts.google.com/ServiceLogin?service=wise&passive=true&continue=http://drive.google.com/")!)
            self.showPresentation()
            self.refreshActions()
        })
        */
        sheet.addAction(UIAlertAction(title: "YouTube", style: .default) { _ in
            let alert = UIAlertController(title: "YouTube", message: nil, preferredStyle: .alert)
            alert.addTextField(configurationHandler: { textField in
                textField.keyboardType = .webSearch
                textField.placeholder = "Search YouTube videos"
                textField.returnKeyType = .search
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Search", style: .default, handler: { _ in
                guard let text = alert.textFields?.first?.text, !text.isEmpty else {
                    return
                }
                // Turn the text into a query if it doesn't contain a period.
                var address = URLComponents(string: "https://m.youtube.com/results")!
                address.queryItems = [URLQueryItem(name: "q", value: text)]
                self.presentationView.attachment = .webPage(address.url!)
                self.showPresentation()
                self.refreshActions()
            }))
            alert.textFields?.first?.delegate = self
            self.present(alert, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Search...", style: .default) { _ in self.showWebPageAlert() })
        sheet.addCancel()
        if let button = self.recordBar.button(for: .presentWeb) {
            sheet.configurePopOver(sourceView: button, sourceRect: button.bounds)
        }
        self.present(sheet, animated: true)
    }

    private func startRecording() {
        guard Recorder.instance.state != .recording else {
            return
        }

        if self.isPresenting || self.mediaRequestInfo != nil {
            self.updateAttachment()
        } else {
            // Don't expose attachment until user chooses to present.
            self.attachment = nil
            self.lastRecordingContainsPresentation = false
        }

        self.feedButton.hideAnimated()
        self.closeButton.hideAnimated()

        // Do not allow navigation while recording.
        self.pager?.isPagingEnabled = false
        // Do not allow screen to turn off while recording.
        UIApplication.shared.isIdleTimerDisabled = true

        // Set up the drawables for the recorder.
        Recorder.instance.drawables = [
            self.presentationView,
            self.cameraView,
            self.videoView,
            self.markerView,
        ]
        Recorder.instance.startRecording(locale: self.presetStream?.transcriptionLocale)

        self.presetStream?.reportStatus(.recording)
        self.presentationView.isRecording = true
        self.recordBar.isRecording = true
    }

    private func stopRecording() {
        Recorder.instance.stopRecording() { recording in
            self.videoView.pause()
            self.videoView.seek(to: 0)
            Recorder.instance.zoom(to: 1)
            DispatchQueue.main.async {
                self.presentationView.isRecording = false
                self.recordBar.isRecording = false
                self.markerView.isHidden = true
                self.presetStream?.reportStatus(.idle)
                if self.presetStream == nil, let url = UIPasteboard.general.url, url.host != "watch.fika.io" {
                    // Remember old clipboard URL before it gets set by the review view controller.
                    // TODO: More obvious logic behind when clipboard gets modified.
                    self.clipboardURL = url
                }
                let review = self.storyboard?.instantiateViewController(withIdentifier: "Review") as! ReviewViewController
                if let attachment = self.attachment {
                    review.attachments = [attachment]
                }
                review.delegate = self
                review.containsPresentation = self.lastRecordingContainsPresentation
                self.lastRecordingContainsPresentation = false
                review.presetStream = self.presetStream
                review.recording = recording
                review.type = self.presetStream != nil ? .reply : .broadcast
                self.present(review, animated: false) { _ in self.refresh() }
            }
        }
        self.pager?.isPagingEnabled = true
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func updateAttachment() {
        if let info = self.mediaRequestInfo, let url = info.pageURL {
            self.attachment = ChunkAttachment(title: info.pageTitle ?? "Video", url: url)
            self.lastRecordingContainsPresentation = true
            return
        }
        switch self.presentationView.attachment {
        case let .document(url), let .webPage(url):
            // TODO: Track web page URLs somehow...
            self.attachment = ChunkAttachment(title: "TODO", url: url)
            self.lastRecordingContainsPresentation = true
        case .image(_):
            // TODO: Also upload image files.
            self.lastRecordingContainsPresentation = true
        default:
            self.attachment = nil
        }
    }

    private dynamic func updateOrientation() {
        let screen = UIScreen.main.bounds
        self.gradientView.frame = screen
        self.markerView.frame = screen
        if self.videoView.isHidden {
            self.presentationView.frame = screen
            if self.cameraView.isMinimized {
                self.cameraView.minimize()
            } else {
                self.cameraView.set(frame: UIScreen.main.bounds, cornerRadius: 0, animated: false)
            }
        } else {
            self.updateVideoFrames(enter: false)
        }
    }

    private func updateVideoFrames(enter: Bool) {
        // Calculate a 16:9 frame that covers the bottom in portrait and goes in the corner in landscape.
        // Also calculate the desired coverage of the rest of the view.
        let screen = UIScreen.main.bounds
        let videoSize: CGSize
        let otherSize: CGSize
        if screen.width > screen.height {
            let h = round(min(screen.height / 2.5, 200))
            videoSize = CGSize(width: round(h * 16 / 9), height: h)
            otherSize = screen.size
        } else {
            videoSize = CGSize(width: screen.width, height: round(screen.width * 9 / 16))
            otherSize = CGSize(width: screen.width, height: screen.height - videoSize.height)
        }

        // Place the frame in the bottom right (will coincide with bottom left for portrait).
        // Create from/to frames so the video can be animated in from the bottom (if enter == true).
        let base = CGRect(origin: .zero, size: videoSize)
        let from = base.offsetBy(dx: screen.width - videoSize.width, dy: screen.height)
        let to = from.offsetBy(dx: 0, dy: -videoSize.height)

        if self.cameraView.isMinimized && !enter {
            self.cameraView.minimize()
        } else {
            self.cameraView.unsetShadow()
            self.cameraView.set(frame: CGRect(origin: .zero, size: otherSize), cornerRadius: 0, animated: true)
        }

        let videoAnim = POPBasicAnimation(propertyNamed: kPOPViewFrame)!
        videoAnim.duration = 0.2
        videoAnim.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
        videoAnim.fromValue = enter ? from : self.videoView.frame
        videoAnim.toValue = to
        self.videoView.pop_add(videoAnim, forKey: "frame")

        let presoAnim = POPBasicAnimation(propertyNamed: kPOPViewFrame)!
        presoAnim.duration = 0.2
        presoAnim.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
        presoAnim.fromValue = self.presentationView.frame
        presoAnim.toValue = CGRect(origin: .zero, size: otherSize)
        self.presentationView.pop_add(presoAnim, forKey: "frame")
    }

    private dynamic func viewSwipedDown(recognizer: UISwipeGestureRecognizer) {
        guard self.videoView.isHidden else {
            self.hideVideoView()
            return
        }
        guard !self.isPresenting else {
            self.hidePresentation()
            return
        }
        guard self.presetStream != nil else {
            return
        }
        self.dismiss(animated: true, completion: nil)
    }

    // MARK: - Events

    private func handleApplicationActiveStateChanged(active: Bool) {
        if !active && Recorder.instance.state == .recording {
            // Recording will crash if it tries to continue in background.
            self.stopRecording()
        }

        if active || Recorder.instance.configuration == .audioOnly {
            self.screenCurtain.hideAnimated()
        } else {
            // Show blurred background image for nicer app switcher screenshot.
            self.screenCurtain.alpha = 0
            self.screenCurtain.isHidden = false
            UIView.animate(withDuration: 0.1, delay: 0.1, options: .curveEaseIn, animations: {
                self.screenCurtain.alpha = 1
            }, completion: nil)
        }
        self.refresh()
    }

    private func handleRecorderUnavailable(reason: AVCaptureSessionInterruptionReason) {
        switch reason {
        case .audioDeviceInUseByAnotherClient:
            // Probably in a phone call.
            break
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            guard Recorder.instance.configuration != .audioOnly else {
                return
            }
            self.enterAudioMode()
            self.refreshActions()
            if UIApplication.shared.applicationState == .active {
                let alert = UIAlertController(title: "Video Unavailable", message: "To record video, go into full screen mode.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Okay", style: .default))
                self.present(alert, animated: true)
            }
        default:
            break
        }
    }

    private func handleUnplayedCountChanged() {
        self.refresh()
    }
}
