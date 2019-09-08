import AVFoundation
import SafariServices
import UIKit

class GetStartedViewController: UIViewController {

    // MARK: - UIViewController

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override func viewDidDisappear(_ animated: Bool) {
        NotificationCenter.default.removeObserver(self)
        self.playerLayer?.player?.replaceCurrentItem(with: nil)
        self.playerLayer?.removeFromSuperlayer()
        self.playerLayer = nil
    }

    override func viewDidLoad() {
        AppDelegate.applicationActiveStateChanged.addListener(self, method: GetStartedViewController.handleActiveStateChanged)
        AppDelegate.receivedAuthCode.addListener(self, method: GetStartedViewController.handleAuthCode)
        BackendClient.instance.loggedIn.addListener(self, method: GetStartedViewController.handleLoggedIn)
    }

    override func viewWillAppear(_ animated: Bool) {
        let url = Bundle.main.url(forResource: "silent", withExtension: "mp4")!

        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .none
        player.play()

        let layer = AVPlayerLayer(player: player)
        layer.frame = UIApplication.shared.keyWindow!.bounds
        layer.videoGravity = AVLayerVideoGravityResizeAspectFill
        self.playerLayer = layer
        self.view.layer.insertSublayer(layer, at: 0)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(GetStartedViewController.playerItemDidReachEnd(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: player.currentItem)
    }

    override func viewWillLayoutSubviews() {
        self.playerLayer?.frame = UIApplication.shared.keyWindow!.bounds
    }

    // MARK: - Actions

    @IBAction func getStartedTapped(_ sender: Any) {
        let login = self.storyboard?.instantiateViewController(withIdentifier: "Challenge") as! ChallengeViewController
        self.present(login, animated: true, completion: nil)
    }

    @IBAction func termsOfUseTapped(_ sender: Any) {
        UIApplication.shared.open(URL(string: "https://fika.io/legal")!, options: [:])
    }

    // MARK: - Private

    private var playerLayer: AVPlayerLayer?
    private var webController: SFSafariViewController?

    private func handleActiveStateChanged(active: Bool) {
        if active {
            // Resume the player since it got paused in the background.
            self.playerLayer?.player?.play()
        }
    }

    private func handleAuthCode(code: String) {
        // Don't do anything if the user is already logged in.
        guard BackendClient.instance.session == nil else {
            return
        }

        // TODO: Show loading state. Handle failure.
        Intent.logInWithAuthCode(code: code).perform(BackendClient.instance) {
            guard $0.successful else {
                let alert = UIAlertController(title: "Failed to log in", message: "Sorry, something went wrong when logging in. Please try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Okay", style: .default, handler: { _ in self.webController?.dismiss(animated: true) }))
                self.present(alert, animated: true)
                return
            }
        }
    }

    private func handleLoggedIn(session: Session) {
        self.webController?.dismiss(animated: true)
        self.webController = nil

        let vc = self.storyboard!.instantiateViewController(withIdentifier: "RootNavigation")
        self.present(vc, animated: true) {
            UIApplication.shared.keyWindow!.rootViewController = vc
        }
    }

    private dynamic func playerItemDidReachEnd(_ notification: NSNotification) {
        if let item = notification.object as? AVPlayerItem {
            item.seek(to: kCMTimeZero)
        }
    }
}
