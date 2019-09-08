import UIKit

class BlurredImageView: UIImageView {
    override func awakeFromNib() {
        self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        self.blurView!.frame = self.bounds
        self.addSubview(self.blurView!)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.blurView?.frame = self.bounds
    }

    private var blurView: UIVisualEffectView?
}

class BottomSeparatorView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()

        let bottomBorder = CALayer()
        bottomBorder.frame = CGRect(x: 0, y: self.frame.height, width: self.frame.width, height: 0.5)
        bottomBorder.backgroundColor = UIColor.lightGray.cgColor
        self.layer.addSublayer(bottomBorder)
    }
}

class CameraControlButton: UIButton {
    override func awakeFromNib() {
        self.layer.cornerRadius = self.frame.width / 2
        self.layer.shadowOffset = CGSize(width: 0, height: 2)
        self.layer.shadowOpacity = 0.2
        self.layer.shadowRadius = 1
        self.layer.shadowColor = UIColor.lightGray.cgColor
    }
}

class GradientView: UIView {
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.setupGradient()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setupGradient()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.gradient.frame = self.bounds
    }

    private let gradient = CAGradientLayer()

    private func setupGradient() {
        self.layoutIfNeeded()

        self.gradient.frame = self.bounds
        self.gradient.colors = [
            UIColor.black.withAlphaComponent(0.3).cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.4).cgColor,
        ]
        self.gradient.locations = [0, 0.12, 0.78, 1]
        self.gradient.startPoint = CGPoint(x: 0.5, y: 0)
        self.gradient.endPoint = CGPoint(x: 0.5, y: 1)
        self.gradient.rasterizationScale = UIScreen.main.scale
        self.gradient.shouldRasterize = true

        self.layer.insertSublayer(self.gradient, at: 0)
    }
}

class HighlightButton: UIButton {
    var isLoading: Bool = false {
        didSet {
            if self.isLoading {
                self.loader.startAnimating()
                self.setTitle(nil, for: .normal)
                self.isUserInteractionEnabled = false
            } else {
                self.loader.stopAnimating()
                self.setTitle(self.title, for: .normal)
                self.isUserInteractionEnabled = true
            }
        }
    }

    override var isEnabled: Bool {
        didSet {
            self.borderColor = self.isEnabled ?
                self.titleColor(for: .normal) : self.titleColor(for: .disabled)
        }
    }

    override func awakeFromNib() {
        self.layer.cornerRadius = 8
        self.layer.borderColor = self.titleColor(for: .normal)?.cgColor
        self.layer.borderWidth = 2
        self.setTitleColor(UIColor.white, for: .highlighted)
        self.setTitleColor(UIColor.lightGray.withAlphaComponent(0.6), for: .disabled)

        self.title = self.title(for: .normal)

        super.layoutIfNeeded()
        self.loader = UIActivityIndicatorView(frame: self.bounds)
        self.loader.activityIndicatorViewStyle = .gray
        self.loader.hidesWhenStopped = true
        self.loader.color = UIColor.black
        self.addSubview(self.loader)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.backgroundColor = self.titleColor(for: .normal)
        super.touchesBegan(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.backgroundColor = UIColor.clear
        super.touchesCancelled(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.backgroundColor = UIColor.clear
        super.touchesEnded(touches, with: event)
    }

    // MARK: - Private

    private var loader: UIActivityIndicatorView!
    private var title: String?
}

class LoaderButton: CameraControlButton {
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.loader = UIActivityIndicatorView()
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        self.setTitleColor(UIColor.clear, for: .disabled)

        super.layoutIfNeeded()
        self.loader.frame = self.bounds
        self.loader.hidesWhenStopped = true
        self.addSubview(self.loader)
        self.setTitle(nil, for: .disabled)
    }

    var isLoading: Bool = false {
        didSet {
            guard self.isLoading else {
                self.loader.stopAnimating()
                self.isEnabled = true
                return
            }
            self.isEnabled = false
            self.loader.startAnimating()
        }
    }

    // MARK: - Private

    var loader: UIActivityIndicatorView!
}

class SeparatorCell: UITableViewCell {
    var separator: CALayer!

    override func awakeFromNib() {
        self.separator = CALayer()
        self.separator.backgroundColor = UIColor.black.withAlphaComponent(0.05).cgColor
        self.layer.addSublayer(self.separator)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.separator.frame = CGRect(x: 16, y: self.frame.height - 1, width: self.frame.width - 32, height: 0.5)
    }
}

class SearchTextField: UITextField {
    override func awakeFromNib() {
        self.layoutIfNeeded()

        let clearButton = UIButton(frame: CGRect(x: 0, y: 0, width: self.frame.height, height: self.frame.height))
        clearButton.titleLabel!.font = UIFont.materialFont(ofSize: 20)
        clearButton.setTitle("clear", for: .normal)
        clearButton.setTitleColor(UIColor.black, for: .normal)
        clearButton.addTarget(self, action: #selector(SearchTextField.clearClicked), for: .touchUpInside)
        clearButton.isHidden = true

        self.clearButtonMode = .never
        self.rightView = clearButton
        self.rightViewMode = .always
        self.rightView?.isHidden = true

        self.addTarget(self, action: #selector(SearchTextField.editingDidBegin), for: .editingDidBegin)
        self.addTarget(self, action: #selector(SearchTextField.editingChanged), for: .editingChanged)
    }

    func clearClicked() {
        self.text = ""
        self.sendActions(for: .editingChanged)
        self.becomeFirstResponder()
    }

    func editingChanged() {
        self.rightView!.isHidden = self.text == nil || self.text == ""
    }

    func editingDidBegin() {
        self.rightView!.isHidden = self.text == nil || self.text == ""
    }
}
