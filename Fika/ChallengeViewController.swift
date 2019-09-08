import Crashlytics
import UIKit

class ChallengeViewController: UIViewController, UITextFieldDelegate {

    enum State {
        case enterIdentifier, enterSecret
    }

    @IBOutlet weak var authAvatarImage: UIImageView!
    @IBOutlet weak var authTeamImage: UIImageView!
    @IBOutlet weak var authTeamName: UILabel!
    @IBOutlet weak var centerXConstraint: NSLayoutConstraint!
    @IBOutlet weak var codeSentLabel: UILabel!
    @IBOutlet weak var confirmIdentifierButton: HighlightButton!
    @IBOutlet weak var identifierField: InsetTextField!
    @IBOutlet weak var identifierView: UIView!
    @IBOutlet weak var keyboardHeight: NSLayoutConstraint!
    @IBOutlet weak var secretField: InsetTextField!
    @IBOutlet weak var secretView: UIView!

    static var defaultIdentifier: String?

    // MARK: UIViewController

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.secretField.delegate = self
        self.secretField.addTarget(self, action: #selector(ChallengeViewController.autoSubmitSecret), for: .editingChanged)

        self.identifierField.text = ChallengeViewController.defaultIdentifier ?? ""
        self.identifierField.becomeFirstResponder()
        self.identifierField.delegate = self

        self.authAvatarImage.layer.minificationFilter = kCAFilterTrilinear
        self.authTeamImage.layer.minificationFilter = kCAFilterTrilinear

        NotificationCenter.default.addObserver(self, selector: #selector(ChallengeViewController.keyboardEvent), name: .UIKeyboardWillChangeFrame, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.state = .enterIdentifier
        self.identifierField.becomeFirstResponder()

        AppDelegate.documentImported.addListener(self, method: ChallengeViewController.handleDocumentImported)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Hide the keyboard.
        self.view.endEditing(true)

        AppDelegate.documentImported.removeListener(self)
    }

    // MARK: Actions

    @IBAction func backFromEnterSecretTapped(_ sender: AnyObject) {
        self.state = .enterIdentifier
    }

    @IBAction func backTapped(_ sender: AnyObject) {
        self.dismiss(animated: true, completion: nil)
    }

    @IBAction func confirmIdentifierTapped(_ sender: AnyObject) {
        guard let identifier = self.identifierField.text, identifier.contains("@") else {
            self.showAlert("That doesn't look like an e-mail.", action: "Try again")
            return
        }
        self.requestChallenge()
    }

    // MARK: - Private

    private var state: State = .enterIdentifier {
        didSet {
            var offset: CGFloat = 0
            switch self.state {
            case .enterIdentifier:
                self.identifierField?.becomeFirstResponder()
            case .enterSecret:
                self.secretField.text = ""
                self.secretField.becomeFirstResponder()
                offset = -self.view.frame.width
            }
            // Transition between identifier and secret views.
            self.view.layoutIfNeeded()
            UIView.animate(withDuration: 0.25) {
                self.centerXConstraint.constant = offset
                self.view.layoutIfNeeded()
            }
        }
    }

    private dynamic func autoSubmitSecret() {
        guard let text = self.secretField.text, text.characters.count == 6 else {
            return
        }
        self.verifySecret()
        Answers.logCustomEvent(withName: "Enter Secret", customAttributes: ["DocumentImport": "No"])
    }

    private dynamic func keyboardEvent(notification: NSNotification) {
        self.view.layoutIfNeeded()
        let info = notification.userInfo!
        UIView.beginAnimations(nil, context: nil)
        UIView.setAnimationCurve(UIViewAnimationCurve(rawValue: (info[UIKeyboardAnimationCurveUserInfoKey] as! NSNumber).intValue)!)
        UIView.setAnimationDuration((info[UIKeyboardAnimationDurationUserInfoKey] as! NSNumber).doubleValue)
        UIView.setAnimationBeginsFromCurrentState(true)
        let frame = info[UIKeyboardFrameEndUserInfoKey] as! CGRect
        self.keyboardHeight.constant = frame.minY - UIApplication.shared.keyWindow!.bounds.height
        self.view.layoutIfNeeded()
        UIView.commitAnimations()
    }

    private func requestChallenge(preferPhoneCall shouldCall: Bool = false) {
        // Send activation code SMS or e-mail.
        self.confirmIdentifierButton.isLoading = true
        Intent.requestChallenge(identifier: self.identifierField.text!, preferPhoneCall: shouldCall).perform(BackendClient.instance) { result in
            self.confirmIdentifierButton.isLoading = false
            guard result.successful else {
                switch result.code {
                case 403:
                    let vc = self.storyboard?.instantiateViewController(withIdentifier: "NotWhitelisted") as! NotWhitelistedViewController
                    vc.email = self.identifierField.text!
                    self.present(vc, animated: true)
                default:
                    self.showAlert("Something went wrong. Please check your email and internet connection.") {
                        self.state = .enterIdentifier
                    }
                }
                return
            }
            self.codeSentLabel.text = "We sent you an email, please check it to continue."
            if let account = result.data?["account"] as? [String: Any] {
                if let name = account["display_name"] as? String {
                    self.codeSentLabel.text = "Hi \(name.shortName)! We sent you an email, please check it to continue."
                }
                if let image = account["image_url"] as? String {
                    self.authAvatarImage.af_setImage(withURL: URL(string: image)!)
                } else {
                    self.authAvatarImage.image = UIImage(named: "defaultAvatar")
                }
            } else {
                self.authAvatarImage.image = UIImage(named: "defaultAvatar")
            }
            if let team = result.data?["team"] as? [String: Any], let name = team["name"] as? String {
                if let image = team["image_url"] as? String {
                    self.authTeamImage.af_setImage(withURL: URL(string: image)!)
                } else {
                    self.authTeamImage.image = UIImage(named: "fika")
                }
                self.authTeamImage.isHidden = false
                self.authTeamName.text = name
                self.authTeamName.isHidden = false
            } else {
                self.authTeamImage.isHidden = true
                self.authTeamName.isHidden = true
            }
            self.state = .enterSecret
        }
    }

    /// Shows an alert with an optional completion handler.
    private func showAlert(_ message: String, action: String = "Okay", title: String = "Uh oh!", handler: (() -> ())? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: action, style: .cancel) { _ in handler?() })
        self.present(alert, animated: true)
    }

    private func verifySecret() {
        guard let identifier = self.identifierField.text, let secret = self.secretField.text, secret.characters.count == 6 else {
            self.showAlert("You must enter a valid code.", action: "Try again")
            return
        }
        self.codeSentLabel.text = "Please wait while we get your account set up..."
        self.secretField.isEnabled = false
        self.secretField.textColor = .lightGray
        Intent.respondToChallenge(identifier: identifier, secret: secret, firstStreamParticipant: nil).perform(BackendClient.instance) {
            guard $0.successful else {
                let message: String
                switch $0.code {
                case 400:
                    message = "That doesn't look like the code we sent."
                case 409:
                    message = "An account with that identifier already exists."
                default:
                    message = "We failed to validate your code at this time."
                }
                self.showAlert(message, action: "Try again") {
                    self.codeSentLabel.text = "Look for the email we sent to \(self.identifierField.text!)."
                    self.secretField.isEnabled = true
                    self.secretField.text = ""
                    self.secretField.textColor = .black
                    self.secretField.becomeFirstResponder()
                }
                return
            }
            // Reset the default identifier.
            ChallengeViewController.defaultIdentifier = nil
            // Take the user to the main UI.
            let vc = self.storyboard!.instantiateViewController(withIdentifier: "RootNavigation")
            vc.modalTransitionStyle = .flipHorizontal
            self.identifierView.isHidden = true
            self.present(vc, animated: true) {
                UIApplication.shared.keyWindow!.rootViewController = vc
            }
        }
    }

    // MARK: - UITextFieldDelegate

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard textField == self.secretField else {
            return true
        }
        let allowedCharacters = "0123456789".characters
        let text = (textField.text! as NSString).replacingCharacters(in: range, with: string) as String
        textField.text = String(text.characters.filter(allowedCharacters.contains))
        self.autoSubmitSecret()
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch textField {
        case self.identifierField:
            self.confirmIdentifierTapped(self.confirmIdentifierButton)
        case self.secretField:
            self.verifySecret()
            Answers.logCustomEvent(withName: "Enter Secret", customAttributes: ["DocumentImport": "No"])
        default:
            return true
        }
        return false
    }

    // MARK: - Private

    private func handleDocumentImported() {
        guard var url = AppDelegate.getImportedDocumentURL() else {
            return
        }

        // Reset the imported document
        AppDelegate.documentImported.removeListener(self)
        AppDelegate.setImportedDocumentURL(to: url)
        AppDelegate.documentImported.addListener(self, method: ChallengeViewController.handleDocumentImported)

        // Use the retrieved URL to authenticate
        url.deletePathExtension()
        self.secretField.text = url.lastPathComponent.components(separatedBy: "-").first
        self.verifySecret()
        Answers.logCustomEvent(withName: "Enter Secret", customAttributes: ["DocumentImport": "Yes"])
    }
}

class InsetTextField: UITextField {
    // Placeholder position.
    override func textRect(forBounds bounds: CGRect) -> CGRect {
        return bounds.insetBy(dx: 4, dy: 4)
    }
    
    // Text position.
    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        return bounds.insetBy(dx: 4, dy: 4)
    }
}
