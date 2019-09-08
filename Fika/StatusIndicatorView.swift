import UIKit

class StatusIndicatorView: UIView {

    @IBOutlet weak var loader: UIActivityIndicatorView!
    @IBOutlet weak var confirmationLabel: UILabel!

    static func create(container: UIView) -> StatusIndicatorView {
        let view = Bundle.main.loadNibNamed("StatusIndicatorView", owner: self, options: nil)?[0] as! StatusIndicatorView
        view.frame.size = CGSize(width: 120,height: 120)
        view.center = container.center
        view.isHidden = true
        view.alpha = 0
        container.addSubview(view)
        return view
    }

    override func layoutSubviews() {
        if let container = self.superview {
            self.center = container.center
        }
        super.layoutSubviews()
    }

    func showConfirmation() {
        self.loader.stopAnimating()
        self.confirmationLabel.font = UIFont.materialFont(ofSize: 47)
        self.confirmationLabel.isHidden = false
        self.show(temporary: true)
    }

    func showLoading() {
        self.confirmationLabel.isHidden = true
        self.loader.startAnimating()
        self.show()
    }

    private func show(temporary: Bool = false) {
        self.showAnimated()

        if temporary {
            // Automatically hide after a short delay
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(1400 * NSEC_PER_MSEC)) / Double(NSEC_PER_SEC)) {
                self.hide()
            }
        }
    }

    func hide() {
        self.hideAnimated() {
            self.loader.stopAnimating()
            self.confirmationLabel.isHidden = true
        }
    }
}
