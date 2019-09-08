import Crashlytics
import UIKit

class SetNameViewController: UIViewController,
    UITextFieldDelegate,
    UIImagePickerControllerDelegate,
    UINavigationControllerDelegate {

    @IBOutlet weak var confirmButton: HighlightButton!
    @IBOutlet weak var nameTextField: UITextField!
    @IBOutlet weak var avatarView: UIImageView!

    override func viewDidLoad() {
        super.viewDidLoad()

        self.imagePicker.allowsEditing = true
        self.imagePicker.delegate = self

        self.nameTextField.delegate = self
        self.nameTextField.becomeFirstResponder()

        // Prefill image if this is an existing account
        if let url = BackendClient.instance.session?.imageURL {
            self.avatarView.af_setImage(withURL: url)
        }
        self.avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(SetNameViewController.handleAvatarTapped)))

        // Prefill name from an existing session or from the AddressBook
        if let name = BackendClient.instance.session?.displayName {
            self.nameTextField.text = name
        }
        Answers.logCustomEvent(withName: "Set Name Shown", customAttributes: [:])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.view.endEditing(true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }

    @IBAction func confirmTapped(_ sender: AnyObject) {
        guard let text = self.nameTextField.text , !text.isEmpty else {
            self.showAlert(
                "Uh oh!",
                message: "That doesn't look like your name.",
                cancelTitle: "Try again",
                actionTitle: nil,
                tappedActionCallback: nil)
            return
        }

        var image: Intent.Image?
        if let data = self.userPhotoData {
            image = Intent.Image(format: .jpeg, data: data)
        }

        self.confirmButton.isLoading = true

        let changeImage = Promise<Void> { resolve, reject in
            guard let image = image else {
                resolve()
                return
            }
            Intent.changeUserImage(image: image).perform(BackendClient.instance) { result in
                guard result.successful else {
                    reject(result.error!)
                    return
                }
                resolve()
            }
        }

        let changeName = Promise<Void> { resolve, reject in
            Intent.changeDisplayName(newDisplayName: text).perform(BackendClient.instance) { result in
                guard result.successful else {
                    reject(result.error!)
                    return
                }
                resolve()
            }
        }

        Promise.all([changeImage, changeName]).then({ _ in
            DispatchQueue.main.async {
                self.confirmButton.isLoading = false
                self.dismiss(animated: true, completion: nil)
            }
        }, { error in
            DispatchQueue.main.async {
                self.confirmButton.isLoading = false
                self.showAlert(
                    "Uh oh!",
                    message: "Something went wrong. Please try again!",
                    cancelTitle: "Okay",
                    actionTitle: nil,
                    tappedActionCallback: { _ in
                        self.dismiss(animated: true, completion: nil)
                })
            }
        })
    }

    private dynamic func handleAvatarTapped() {
        self.present(self.imagePicker, animated: true, completion: nil)
    }

    // MARK: - UIImagePickerControllerDelegate

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : Any]) {
        defer {
            picker.dismiss(animated: true, completion: nil)
        }

        guard let image = info[UIImagePickerControllerEditedImage] as? UIImage, let imageData = UIImageJPEGRepresentation(image, 0.8) else {
            Answers.logCustomEvent(withName: "Profile Image Picker", customAttributes: ["Result": "Cancel"])
            return
        }

        self.userPhotoData = imageData
        self.avatarView.image = image

        Answers.logCustomEvent(withName: "Profile Image Picker", customAttributes: ["Result": "PickedImage"])
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.confirmTapped(self.confirmButton)
        return false
    }

    // MARK: Private

    private let imagePicker = UIImagePickerController()
    private var userPhotoData: Data?

    private func showAlert(_ title: String, message: String, cancelTitle: String, actionTitle: String?, tappedActionCallback: ((Bool) -> Void)?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let action = actionTitle {
            let positiveAction = UIAlertAction(title: action, style: .default) { action in
                tappedActionCallback?(true) }
            alert.addAction(positiveAction)
            if #available(iOS 9.0, *) {
                alert.preferredAction = positiveAction
            }
        }
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { action in
            tappedActionCallback?(false) })
        
        self.present(alert, animated: true, completion: nil)
    }
}
