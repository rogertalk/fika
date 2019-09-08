import UIKit

class RootNavigationViewController: UINavigationController {
    override var shouldAutorotate: Bool {
        return Recorder.instance.state != .recording
    }
}
