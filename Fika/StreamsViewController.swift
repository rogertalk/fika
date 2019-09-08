import SafariServices
import UIKit
import UserNotifications

class StreamsViewController: UIViewController,
    ServiceImportPickerDelegate,
    PagerPage,
    UITableViewDelegate,
    UITableViewDataSource {

    @IBOutlet weak var streamsTable: UITableView!
    @IBOutlet weak var titleImage: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var settingsButton: CameraControlButton!

    var streams = [Stream]()
    var pager: Pager?

    override func viewDidAppear(_ animated: Bool) {
        self.pollStreamsIfEmpty()
    }

    override func viewDidLoad() {
        self.streamsTable.delegate = self
        self.streamsTable.dataSource = self
        self.streamsTable.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 40, right: 0)

        self.streams = StreamService.instance.streams.values

        AppDelegate.receivedAuthCode.addListener(self, method: StreamsViewController.handleAuthCode)
        StreamService.instance.changed.addListener(self, method: StreamsViewController.handleStreamsChanged)

        // TODO: Find better way of getting a team name.
        if let service = BackendClient.instance.session?.services.first, let team = service.team {
            self.titleLabel.text = team.name
            if let url = team.imageURL {
                self.titleImage.af_setImage(withURL: url, placeholderImage: UIImage(named: "fika"))
            } else {
                self.titleImage.image = UIImage(named: "fika")
            }
        } else {
            self.titleLabel.text = "Channels"
        }

        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(StreamsViewController.tableLongPressed))
        self.streamsTable.addGestureRecognizer(longPressRecognizer)

        self.refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.settingsButton.isHidden = settings.authorizationStatus == .authorized
            }
        }
    }

    // MARK: - Action

    @IBAction func addGroupTapped(_ button: UIButton) {
        let sheet = UIAlertController(title: "Import group from...", message: nil, preferredStyle: .actionSheet)
        self.createSlackImportActions(mode: .groups).forEach(sheet.addAction)
        sheet.addAction(UIAlertAction(title: "Create a new group", style: .default) { _ in
            let alert = UIAlertController(title: "Create a new group", message: "What would you like to name it?", preferredStyle: .alert)
            var nameField: UITextField?
            alert.addTextField(configurationHandler: { textField in
                nameField = textField
                textField.autocapitalizationType = .words
                textField.placeholder = "Group Name"
            })
            alert.addAction(UIAlertAction(title: "Add People", style: .default) { _ in
                guard let name = nameField?.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                    return
                }
                let vc = self.storyboard!.instantiateViewController(withIdentifier: "ParticipantsPicker") as! ParticipantsPickerController
                vc.streamTitle = name
                self.present(vc, animated: true)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(alert, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = button
            popover.sourceRect = button.bounds
        }
        self.present(sheet, animated: true)
    }

    @IBAction func addMeetingTapped(_ sender: Any) {
        let meeting = self.storyboard?.instantiateViewController(withIdentifier: "CreateMeeting")
        self.present(meeting!, animated: true)
    }

    @IBAction func addMemberTapped(_ button: UIButton) {
        let sheet = UIAlertController(title: "Add people via...", message: nil, preferredStyle: .actionSheet)
        self.createSlackImportActions(mode: .users).forEach(sheet.addAction)
        sheet.addAction(UIAlertAction(title: "Email invite", style: .default) { _ in
            let addMembers = self.storyboard?.instantiateViewController(withIdentifier: "AddMembers") as! AddUsersViewController
            self.present(addMembers, animated: true, completion: nil)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = button
            popover.sourceRect = button.bounds
        }
        self.present(sheet, animated: true)
    }

    @IBAction func cameraTapped(_ sender: Any) {
        self.pager?.pageTo(.create)
    }

    @IBAction func settingsTapped(_ sender: Any) {
        let alert = UIAlertController(title: "Settings", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Enable Notifications", style: .default) { _ in
            UIApplication.shared.open(URL(string: UIApplicationOpenSettingsURLString)!, options: [:], completionHandler: nil)
        })
        alert.addAction(UIAlertAction(title: "Done", style: .cancel, handler: nil))
        self.present(alert, animated: true, completion: nil)
    }

    // MARK: - PagerPage

    func didPage(swiped: Bool) {
    }

    // MARK: - ServiceImportPickerDelegate

    func serviceImport(_ picker: ServiceImportPickerViewController, didFinishPickingStream stream: Stream) {
        picker.dismiss(animated: true, completion: nil)
        self.pager?.pageTo(.create)
    }

    func serviceImport(_ picker: ServiceImportPickerViewController, requestServiceReconnect serviceId: String) {
        picker.dismiss(animated: true, completion: nil)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !self.isLoading &&
            StreamService.instance.nextPageCursor != nil &&
            scrollView.contentOffset.y >
            (scrollView.contentSize.height - scrollView.frame.size.height * 1.5) else {
                return
        }

        self.isLoading = true
        StreamService.instance.loadNextPage() { _ in
            self.isLoading = false
        }
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return self.sections[indexPath.section].rowHeight
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = self.sections[indexPath.section]
        let cell = tableView.dequeueReusableCell(withIdentifier: section.cellReuseIdentifier, for: indexPath)
        section.populateCell(indexPath.row, cell: cell)
        return cell
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return self.sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.sections[section].count
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let sectionObject = self.sections[section]
        return sectionObject.headerTitle == nil || sectionObject.count == 0 ? 0 : 50
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let sectionObject = self.sections[section]
        guard let header = sectionObject.headerTitle, sectionObject.count > 0 else {
            return nil
        }
        // Containing view for the section header label
        let headerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.frame.width, height: 50))
        headerView.backgroundColor = UIColor.white

        // Create section label with header text
        let sectionLabel = UILabel()
        sectionLabel.center = headerView.center
        sectionLabel.font = UIFont.systemFont(ofSize: 12, weight: UIFontWeightSemibold)
        sectionLabel.backgroundColor = UIColor.white
        sectionLabel.textColor = UIColor.lightGray
        sectionLabel.text = "\(header.uppercased()) (\(sectionObject.count))"
        sectionLabel.sizeToFit()
        sectionLabel.frame.origin = CGPoint(x: 16, y: headerView.center.y)
        headerView.addSubview(sectionLabel)

        // TODO: This should be managed from the Section itself.
        let addButton = UIButton(type: .custom)
        addButton.titleLabel?.font = UIFont.materialFont(ofSize: 16)
        addButton.setTitle("add_circle_outline", for: .normal)
        addButton.contentHorizontalAlignment = .right
        addButton.setTitleColor(UIColor.lightGray, for: .normal)
        addButton.titleEdgeInsets = UIEdgeInsets(top: 14, left: 0, bottom: 0, right: 16)
        addButton.frame = CGRect(x: headerView.bounds.width - 50, y: 0, width: 50, height: headerView.bounds.height)
        let action: Selector
        if sectionObject is GroupsSection {
            action = #selector(StreamsViewController.addGroupTapped)
        } else {
            action = #selector(StreamsViewController.addMemberTapped)
        }
        addButton.addTarget(self, action: action, for: .touchUpInside)
        // TODO: Remove this very ugly hack!
        if sectionObject.headerTitle != "Others" {
            headerView.addSubview(addButton)
        }

        let separator = CALayer()
        separator.backgroundColor = UIColor.lightGray.withAlphaComponent(0.6).cgColor
        separator.frame = CGRect(x: 16, y: headerView.frame.height - 0.5, width: headerView.bounds.width - 32, height: 0.5)
        headerView.layer.insertSublayer(separator, at: 0)
        return headerView
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        let (success, action) = self.sections[indexPath.section].canSelect(indexPath.row)
        self.perform(action: action, sourceView: nil, sourceRect: .zero)
        return success ? indexPath : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        self.perform(action: self.sections[indexPath.section].handleSelect(indexPath.row),
                     sourceView: nil, sourceRect: .zero)
    }

    // MARK: - Private

    private var isLoading: Bool = false {
        didSet {
            guard oldValue != self.isLoading else {
                return
            }
            // TODO: Use nice animations.
            self.refresh()
        }
    }

    private var sections = [Section]()
    private var webController: SFSafariViewController?
    private var webControllerImportMode: ServiceImportPickerViewController.ImportMode?

    /// Creates an action that either imports via Slack or connects a Slack account.
    private func createSlackImportActions(mode: ServiceImportPickerViewController.ImportMode) -> [UIAlertAction] {
        let session = BackendClient.instance.session!
        let slacks = session.services.filter({ $0.id == "slack" })
        let connectTitle: String
        if slacks.count > 0 {
            connectTitle = "Connect another Slack team"
        } else {
            connectTitle = "Connect Slack team"
        }
        let connectAction = UIAlertAction(title: connectTitle, style: .default) { _ in
            let url = URL(string: "https://api.rogertalk.com/slack/login?access_token=\(session.accessToken)")!
            let vc = SFSafariViewController(url: url)
            self.webController = vc
            self.webControllerImportMode = mode
            self.present(vc, animated: true)
        }
        guard slacks.count > 0 else {
            return [connectAction]
        }
        var actions = [UIAlertAction]()
        for slack in slacks {
            let alert = UIAlertAction(title: "\(slack.team!.name) (Slack)", style: .default) { _ in
                let picker = self.storyboard?.instantiateViewController(withIdentifier: "ServiceImportPicker") as! ServiceImportPickerViewController
                picker.delegate = self
                picker.service = slack
                picker.mode = mode
                self.present(picker, animated: true)
            }
            actions.append(alert)
        }
        actions.append(connectAction)
        return actions
    }

    private func refresh() {
        var groupStreams = [Stream]()
        var teamStreams = [Stream]()
        var otherStreams = [Stream]()
        for stream in self.streams {
            if stream.isGroup {
                groupStreams.append(stream)
            } else if stream.hasTeamMember || stream.isSolo {
                teamStreams.append(stream)
            } else {
                otherStreams.append(stream)
            }
        }
        var sections = [Section]()
        sections.append(GroupsSection(streams: groupStreams))
        sections.append(StreamsSection(title: "Team", streams: teamStreams))
        if otherStreams.count > 0 {
            sections.append(StreamsSection(title: "Others", streams: otherStreams))
        }
        if self.isLoading {
            sections.append(LoaderSection())
        }
        self.sections = sections

        self.streamsTable.reloadData()
    }

    private func handleAuthCode(code: String) {
        // Handle auth codes that come in while user is logged in.
        guard let session = BackendClient.instance.session else {
            return
        }
        let services = session.services
        // Just refresh the profile instead of using the auth code.
        Intent.getOwnProfile().perform(BackendClient.instance) { _ in
            self.webController?.dismiss(animated: true) {
                guard let mode = self.webControllerImportMode else {
                    return
                }
                self.webControllerImportMode = nil
                // We don't know which service was connected, so we have to infer it from what was added.
                guard
                    let session = BackendClient.instance.session,
                    let newService = session.services.first(where: { !services.contains($0) })
                    else { return }
                let picker = self.storyboard?.instantiateViewController(withIdentifier: "ServiceImportPicker") as! ServiceImportPickerViewController
                picker.delegate = self
                picker.service = newService
                picker.mode = mode
                self.present(picker, animated: true)
            }
        }
    }

    private func handleStreamsChanged() {
        self.streams = StreamService.instance.streams.values
        self.refresh()
    }

    private dynamic func tableLongPressed(recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else {
            return
        }
        let point = recognizer.location(in: self.streamsTable)
        guard let indexPath = self.streamsTable.indexPathForRow(at: point) else {
            return
        }
        let cell = self.streamsTable.cellForRow(at: indexPath)
        self.perform(action: self.sections[indexPath.section].handleLongPress(indexPath.row),
                     sourceView: cell,
                     sourceRect: CGRect(origin: recognizer.location(in: cell), size: .zero).insetBy(dx: -10, dy: -10))
    }

    private func perform(action: Action, sourceView: UIView?, sourceRect: CGRect) {
        guard let action = action as? StreamAction else {
            return
        }

        switch action {
        case let .showAlert(alert):
            self.present(alert, animated: true, completion: nil)
        case let .selectStream(stream):
            let chunks = self.storyboard?.instantiateViewController(withIdentifier: "Chunks") as! ChunksViewController
            chunks.stream = stream
            self.present(chunks, animated: true, completion: nil)
        case let .showOptions(stream):
            let names = stream.isGroup ? stream.otherParticipants.map({ $0.displayName }).joined(separator: ", ") : nil
            let sheet = UIAlertController(title: stream.title, message: names, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Ping", style: .default, handler: { _ in
                Intent.buzz(streamId: stream.id).perform(BackendClient.instance)
            }))
            sheet.addAction(UIAlertAction(title: "Hide", style: .destructive, handler: { _ in
                StreamService.instance.removeStreamFromRecents(stream: stream)
                Intent.hideStream(streamId: stream.id).perform(BackendClient.instance) { _ in
                    StreamService.instance.removeStreamFromRecents(stream: stream)
                }
            }))
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = sourceView
                popover.sourceRect = sourceRect
            }
            self.present(sheet, animated: true)
        default:
            break
        }
    }

    private func pollStreamsIfEmpty(after seconds: TimeInterval = 1) {
        guard StreamService.instance.streams.count == 0 else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            StreamService.instance.loadStreams() { _ in
                self.pollStreamsIfEmpty(after: seconds * 2)
            }
        }
    }
}

class StreamCell: UITableViewCell {
    @IBOutlet weak var avatarImageView: UIImageView!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var unplayedCountLabel: AlertLabel!

    var stream: Stream? {
        didSet {
            guard oldValue !== self.stream else {
                return
            }
            if let stream = oldValue {
                stream.changed.removeListener(self)
            }
            if let stream = self.stream {
                stream.changed.addListener(self, method: StreamCell.updateStatus)
            }
            self.updateStatus()
        }
    }

    override func prepareForReuse() {
        self.avatarImageView.af_cancelImageRequest()
        self.avatarImageView.image = nil
        self.avatarImageView.layer.cornerRadius = 17
        self.statusLabel.text = nil
        self.statusLabel.isHidden = true
        self.stream = nil
        self.titleLabel.textColor = .black
        self.unplayedCountLabel.isHidden = true
        self.unplayedCountLabel.text = nil
    }

    func updateStatus() {
        guard let stream = self.stream else {
            self.statusLabel.isHidden = true
            return
        }

        let unplayedCount = stream.unplayedChunks.count
        if unplayedCount > 0 {
            self.unplayedCountLabel.isHidden = false
            self.unplayedCountLabel.text = unplayedCount.description
        } else {
            self.unplayedCountLabel.isHidden = true
        }

        if stream.currentUserDidMissSync {
            self.statusLabel.text = "Send in your sync video!"
            self.statusLabel.textColor = .fikaRed
            self.statusLabel.blink()
            if self.unplayedCountLabel.isHidden {
                self.unplayedCountLabel.isHidden = false
                self.unplayedCountLabel.text = "!"
            }
        } else if let participant = stream.nonIdleParticipant {
            let activity: String
            switch participant.activityStatus {
            case .playing:
                activity = "watching"
            case .recording:
                activity = "talking"
            default:
                activity = "active"
            }
            self.statusLabel.text = "\(participant.displayName) is \(activity)..."
            self.statusLabel.textColor = .fikaBlue
            self.statusLabel.blink()
        } else {
            self.statusLabel.alpha = 1
            self.statusLabel.layer.removeAllAnimations()
            self.statusLabel.textColor = .lightGray
            if
                let id = stream.serviceContentId, id.service == "slack",
                let services = BackendClient.instance.session?.services,
                let team = services.first(where: { $0.team?.id == id.team })?.team
            {
                // TODO: Support more than Slack.
                self.statusLabel.isHidden = false
                self.statusLabel.text = "\(team.name) (Slack)"
            } else if let chunk = stream.chunks.last {
                let action: String
                let actionDate: Date
                let mostRelevantParticipant = stream.otherParticipants.max(by: { a, b in
                    if a.playedUntil == b.playedUntil {
                        return a.playedUntilChanged < b.playedUntilChanged
                    }
                    return a.playedUntil < b.playedUntil
                })
                if let participant = mostRelevantParticipant, stream.hasCurrentUserReplied {
                    if participant.playedUntil == chunk.end {
                        if stream.isGroup {
                            action = "\(participant.displayName.shortName) opened"
                        } else {
                            action = "Opened"
                        }
                        actionDate = participant.playedUntilChangedDate
                    } else {
                        action = "Delivered"
                        actionDate = chunk.endDate
                    }
                } else {
                    action = "Received"
                    actionDate = chunk.endDate
                }
                self.statusLabel.text = "\(action) \(actionDate.timeLabel)"
                self.statusLabel.isHidden = false
            } else if stream.isInvitation {
                self.titleLabel.textColor = .lightGray
                self.statusLabel.text = "Invited"
                self.statusLabel.isHidden = false
            } else {
                self.statusLabel.isHidden = true
            }
        }
    }
}

class AlertLabel: UILabel {
    override var isHighlighted: Bool {
        didSet {
            self.backgroundColor = .fikaRed
        }
    }
}

enum StreamAction: Action {
    case nothing
    case selectStream(stream: Stream)
    case showAlert(alert: UIAlertController)
    case showOptions(stream: Stream)
}

class AddMembersSection: Section {
    let cellReuseIdentifier = "AddCell"
    let count = 1
    let headerTitle: String? = nil
    let rowHeight: CGFloat = 100
}

class LoaderSection: Section {
    let cellReuseIdentifier = "LoaderCell"
    let count = 1
    let headerTitle: String? = nil
    let rowHeight: CGFloat = 60
}

class StreamsSection: Section {
    let cellReuseIdentifier = "StreamCell"
    let rowHeight: CGFloat = 66

    var count: Int {
        return self.streams.count
    }

    var headerTitle: String?

    init(title: String, streams: [Stream]) {
        self.headerTitle = title
        self.streams = streams
    }

    func canSelect(_ row: Int) -> (Bool, Action) {
        let stream = self.streams[row]

        let selectable = !stream.isInvitation
        if selectable {
            return (true, StreamAction.nothing)
        }

        let body: String
        if let domain = BackendClient.instance.session?.teamDomain {
            body = "\(stream.title) hasn't installed fika.io yet. Make sure that they sign up with their \(domain) email."
        } else {
            body = "\(stream.title) hasn't installed fika.io yet."
        }
        let alert = UIAlertController(title: "Not using fika.io yet", message: body, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Okay", style: .default))
        return (false, StreamAction.showAlert(alert: alert))
    }

    func handleLongPress(_ row: Int) -> Action {
        return StreamAction.showOptions(stream: self.streams[row])
    }

    func handleSelect(_ row: Int) -> Action {
        return StreamAction.selectStream(stream: self.streams[row])
    }

    func populateCell(_ row: Int, cell: UITableViewCell) {
        let stream = self.streams[row]

        let cell = cell as! StreamCell
        cell.stream = stream
        cell.titleLabel.text = stream.title

        if let other = stream.otherParticipants.first {
            if let url = other.imageURL {
                cell.avatarImageView.af_setImage(withURL: url)
            } else {
                cell.avatarImageView.image = UIImage(named: "single")
            }
        } else if let url = BackendClient.instance.session?.imageURL {
            cell.avatarImageView.af_setImage(withURL: url)
        }
    }

    let streams: [Stream]
}

class GroupsSection: StreamsSection {
    init(streams: [Stream]) {
        super.init(title: "Groups", streams: streams)
    }

    override func populateCell(_ row: Int, cell: UITableViewCell) {
        let stream = self.streams[row]

        let cell = cell as! StreamCell
        cell.avatarImageView.image = stream.image ?? UIImage(named: "group")
        cell.avatarImageView.layer.cornerRadius = 4
        cell.stream = stream
        cell.titleLabel.text = "\(stream.title) (\(stream.otherParticipants.count + 1))"
    }
}
