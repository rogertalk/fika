import SafariServices
import UIKit

class NotWhitelistedViewController: UIViewController {
    var email: String = "" {
        didSet {
            self.updateExplanation()
        }
    }

    @IBOutlet weak var explanationLabel: UILabel!

    override func viewDidLoad() {
        self.template = self.explanationLabel.text!
        self.updateExplanation()
    }

    @IBAction func closeTapped(_ sender: Any) {
        self.dismiss(animated: true)
    }

    private var template = ""

    private func updateExplanation() {
        self.explanationLabel?.text = self.template.replacingOccurrences(of: "{EMAIL}", with: self.email)
    }
}
