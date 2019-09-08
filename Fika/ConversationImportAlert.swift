import SafariServices
import UIKit

protocol ConversationImportDelegate: class {
    var conversationImportAnchorView: UIView { get }
    func conversationImport(didCreateStream stream: Stream)
}

class ConversationImportAlert: ServiceImportPickerDelegate, ParticipantsPickerDelegate {
    enum ImportAction { case createStream, connectFromSlack, invite }

    init(title: String?, message: String?, importActions: [ImportAction], otherActions: [UIAlertAction], owner: UIViewController, delegate: ConversationImportDelegate) {
        self.owner = owner
        self.delegate = delegate
        self.importActions = importActions
        self.otherActions = otherActions
        self.title = title
        self.message = message
        // TODO: This should only be added while the import alert is active.
        AppDelegate.receivedAuthCode.addListener(self, method: ConversationImportAlert.handleAuthCode)
    }

    func show() {
        let sheet = UIAlertController(title: self.title, message: self.message, preferredStyle: .actionSheet)
        self.otherActions.forEach(sheet.addAction)

        self.importActions.forEach {
            switch $0 {
            case .createStream:
                sheet.addAction(UIAlertAction(title: "Create a Group", style: .default) { _ in
                    let alert = UIAlertController(title: "Create a new group", message: "What would you like to name it?", preferredStyle: .alert)
                    var nameField: UITextField?
                    alert.addTextField(configurationHandler: { textField in
                        nameField = textField
                        textField.autocapitalizationType = .words
                        textField.placeholder = "Group Name"
                    })
                    alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in
                        guard let name = nameField?.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                            return
                        }
                        let vc = self.owner?.storyboard?.instantiateViewController(withIdentifier: "ParticipantsPicker") as! ParticipantsPickerController
                        vc.streamTitle = name
                        vc.delegate = self
                        self.owner?.present(vc, animated: true)
                    })
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    self.owner?.present(alert, animated: true)
                })
                break
            case .connectFromSlack:
                sheet.addAction(UIAlertAction(title: "Connect a Slack Conversation", style: .default) { _ in
                    self.present(slackImportSheetFor: .users)
                })
                sheet.addAction(UIAlertAction(title: "Connect a Slack Channel", style: .default) { _ in
                    self.present(slackImportSheetFor: .groups)
                })
                break
            case .invite:
                sheet.addAction(UIAlertAction(title: "Add by Email", style: .default) { _ in
                    let addMembers = self.owner?.storyboard?.instantiateViewController(withIdentifier: "AddUsers") as! AddUsersViewController
                    self.owner?.present(addMembers, animated: true)
                })
                break
            }
        }

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        self.present(actionSheet: sheet)
    }

    // MARK: - ParticipantsPickerDelegate

    func participantsPicker(picker: ParticipantsPickerController, didCreateStream stream: Stream) {
        picker.dismiss(animated: true)
        self.delegate?.conversationImport(didCreateStream: stream)
    }

    // MARK: - ServiceImportPickerDelegate

    func serviceImport(_ picker: ServiceImportPickerViewController, didFinishPickingStream stream: Stream) {
        picker.dismiss(animated: true)
        self.delegate?.conversationImport(didCreateStream: stream)
    }

    func serviceImport(_ picker: ServiceImportPickerViewController, requestServiceReconnect serviceId: String) {
        picker.dismiss(animated: true) { _ in
            self.connectService(id: "slack")
        }
    }

    // MARK: - Private

    private weak var delegate: ConversationImportDelegate?
    private let importActions: [ImportAction]
    private let otherActions: [UIAlertAction]
    private let message: String?
    private weak var owner: UIViewController?
    private let title: String?
    private var webController: SFSafariViewController?
    private var webControllerImportMode: ServiceImportPickerViewController.ImportMode?

    private func connectService(id: String) {
        switch id {
        case "slack":
            let url = URL(string: "https://api.rogertalk.com/slack/login?access_token=\(BackendClient.instance.session!.accessToken)")!
            let vc = SFSafariViewController(url: url)
            self.webController = vc
            self.webControllerImportMode = .groups
            self.owner?.present(vc, animated: true)
        default:
            break
        }
    }

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
            self.connectService(id: "slack")
        }
        guard slacks.count > 0 else {
            return [connectAction]
        }
        var actions = [UIAlertAction]()
        for slack in slacks {
            let alert = UIAlertAction(title: "\(slack.team!.name) (Slack)", style: .default) { _ in
                self.present(importPickerFor: slack, mode: mode)
            }
            actions.append(alert)
        }
        actions.append(connectAction)
        return actions
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
                self.webController = nil
                guard let mode = self.webControllerImportMode else {
                    return
                }
                self.webControllerImportMode = nil
                // We don't know which service was connected, so we have to infer it from what was added.
                guard
                    let session = BackendClient.instance.session,
                    let newService = session.services.first(where: { !services.contains($0) })
                    else
                {
                    // We couldn't find a new service, which probably means the user reconnected an old one.
                    // Show the list of Slack services again.
                    self.present(slackImportSheetFor: mode)
                    return
                }
                self.present(importPickerFor: newService, mode: mode)
            }
        }
    }

    private func present(actionSheet: UIAlertController) {
        if let delegate = self.delegate, let popover = actionSheet.popoverPresentationController {
            popover.sourceView = delegate.conversationImportAnchorView
            popover.sourceRect = delegate.conversationImportAnchorView.bounds
        }
        self.owner?.present(actionSheet, animated: true)
    }

    private func present(importPickerFor service: ConnectedService, mode: ServiceImportPickerViewController.ImportMode) {
        let picker = self.owner?.storyboard?.instantiateViewController(withIdentifier: "ServiceImportPicker") as! ServiceImportPickerViewController
        picker.delegate = self
        picker.service = service
        picker.mode = mode
        self.owner?.present(picker, animated: true)
    }

    private func present(slackImportSheetFor mode: ServiceImportPickerViewController.ImportMode) {
        let sheet = UIAlertController(title: "Import from...", message: nil, preferredStyle: .actionSheet)
        self.createSlackImportActions(mode: mode).forEach(sheet.addAction)
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        self.present(actionSheet: sheet)
    }
}
