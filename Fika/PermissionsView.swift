import AVFoundation
import Speech
import UIKit
import UserNotifications

protocol PermissionsDelegate: class {
    func didReceivePermissions()
}

class PermissionsView: UIView {

    static var hasPermissions: Bool {
        return (
            AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo) == .authorized &&
            (AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeAudio) == .authorized || TARGET_OS_SIMULATOR != 0) &&
            SFSpeechRecognizer.authorizationStatus() == .authorized
        )
    }

    weak var delegate: PermissionsDelegate?

    @IBOutlet weak var enableCameraButton: HighlightButton!
    @IBOutlet weak var enableMicrophoneButton: HighlightButton!
    @IBOutlet weak var enableSpeechButton: HighlightButton!
    @IBOutlet weak var enableNotificationsButton: HighlightButton!

    static func create(frame: CGRect, delegate: PermissionsDelegate) -> PermissionsView {
        let view = Bundle.main.loadNibNamed("PermissionsView", owner: self, options: nil)?[0] as! PermissionsView
        view.frame = frame
        view.delegate = delegate
        return view
    }

    override func awakeFromNib() {
        self.refresh()
    }

    func refresh() {
        let camera = AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo) == .authorized
        let mic = AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeAudio) == .authorized || (TARGET_OS_SIMULATOR != 0)
        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.enableCameraButton.isEnabled = !camera
                self.enableMicrophoneButton.isEnabled = !mic
                self.enableSpeechButton.isEnabled = !speech
                let notifs = settings.authorizationStatus == .authorized
                self.enableNotificationsButton.isEnabled = !notifs
                if camera && mic && speech && self.didTryNotifs {
                    self.delegate?.didReceivePermissions()
                }
            }
        }
    }

    @IBAction func enableCameraTapped(_ sender: Any) {
        guard AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo) != .denied else {
            self.openPermissionSettings()
            return
        }

        AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo) { granted in
            guard granted else {
                return
            }
            self.refresh()
        }
    }

    @IBAction func enableMicrophoneTapped(_ sender: Any) {
        guard AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeAudio) != .denied else {
            self.openPermissionSettings()
            return
        }

        AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeAudio) { granted in
            guard granted else {
                return
            }
            self.refresh()
        }
    }

    @IBAction func enableSpeechRecognitionTapped(_ sender: Any) {
        guard SFSpeechRecognizer.authorizationStatus() != .denied else {
            self.openPermissionSettings()
            return
        }

        SFSpeechRecognizer.requestAuthorization {
            guard $0 == .authorized else {
                // TODO: Do stuff here.
                return
            }
            self.refresh()
        }
    }

    @IBAction func enableNotificationsTapped(_ sender: Any) {
        self.didTryNotifs = true

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus != .denied else {
                self.openPermissionSettings()
                return
            }

            // Ask for a device token from APNS.
            center.requestAuthorization(options: [.badge, .alert, .sound]) { (granted, error) in
                defer {
                    self.refresh()
                }
                guard granted else {
                    // TODO: Handle denied case.
                    NSLog("%@", "WARNING: Did not get notification permission: \(String(describing: error))")
                    return
                }
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private var didTryNotifs = false

    private func openPermissionSettings() {
        AppDelegate.applicationActiveStateChanged.addListener(self, method: PermissionsView.handleApplicationActiveStateChanged)
        UIApplication.shared.open(URL(string: UIApplicationOpenSettingsURLString)!, options: [:], completionHandler: nil)
    }

    private func handleApplicationActiveStateChanged(active: Bool) {
        guard active else {
            return
        }
        self.refresh()
        AppDelegate.applicationActiveStateChanged.removeListener(self)
    }
}
