import UIKit

class MarkerView: UIView, Drawable, UITextViewDelegate {
    override var isHidden: Bool {
        didSet {
            // TODO: Fade out marker before hiding it.
            if self.isHidden {
                self.clear()
            }
        }
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.backgroundColor = .clear

        self.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(MarkerView.handleMarkerPan)))
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(MarkerView.handleTap)))
    }

    func covers(_ rect: CGRect) -> Bool {
        return false
    }

    func draw(into context: CGContext) {
        let shapes = self.layer.sublayers?.flatMap { layer -> (CAShapeLayer, CGPath, CGColor)? in
            guard
                let shape = layer as? CAShapeLayer,
                let path = shape.path,
                let color = shape.strokeColor
                else { return nil }
            return (shape, path, color)
        }

        shapes?.forEach { (shape, path, color) in
            let path = path.copy(strokingWithWidth: shape.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 0)
            context.beginPath()
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
        }

        UIGraphicsPushContext(context)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 5
        shadow.shadowColor = UIColor(white: 0, alpha: 0.6)
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        self.subviews.forEach {
            guard let field = $0 as? UITextView, let text = field.text else {
                return
            }
            let frame = field.frame
            NSString(string: text).draw(in: frame, withAttributes: [
                NSFontAttributeName: field.font!,
                NSShadowAttributeName: shadow,
                NSStrokeColorAttributeName: UIColor.white,
                NSStrokeWidthAttributeName: NSNumber(value: 12),
                ])
            NSString(string: text).draw(in: frame, withAttributes: [
                NSFontAttributeName: field.font!,
                NSForegroundColorAttributeName: field.textColor!,
                ])
        }
        UIGraphicsPopContext()
    }

    func addText() {
        // Add a text field to the marker view.
        let box = self.bounds
        let textView = UITextView(frame: CGRect(x: 30, y: box.height / 2 - 150, width: box.width - 60, height: 100))
        textView.backgroundColor = .clear
        textView.isEditable = true
        textView.keyboardAppearance = .dark
        textView.returnKeyType = .done
        textView.font = UIFont.annotationFont(ofSize: 32)
        textView.textAlignment = .left
        textView.textColor = SettingsManager.markerColor
        textView.tintColor = SettingsManager.markerColor
        textView.delegate = self
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(MarkerView.handleTextViewPan)))
        self.addSubview(textView)
        textView.becomeFirstResponder()
    }

    // MARK: - UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text != "\n" else {
            textView.resignFirstResponder()
            return false
        }
        return true
    }

    // MARK: - Private

    private var markerLayer: CAShapeLayer?

    private let path = UIBezierPath()

    private var isEditing: Bool {
        get {
            return self.subviews.contains(where: { $0.isFirstResponder })
        }
    }

    private func clear() {
        self.subviews.forEach {
            ($0 as? UITextView)?.removeFromSuperview()
        }
        self.layer.sublayers?.forEach {
            ($0 as? CAShapeLayer)?.removeFromSuperlayer()
        }
    }

    private dynamic func handleTextViewPan(recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view else {
            return
        }
        let translation = recognizer.translation(in: self)
        view.frame = view.frame.offsetBy(dx: translation.x, dy: translation.y)
        recognizer.setTranslation(.zero, in: self)
    }

    private dynamic func handleMarkerPan(recognizer: UIPanGestureRecognizer) {
        guard !self.isEditing else {
            return
        }
        let p = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            self.path.move(to: p)
            let layer = CAShapeLayer()
            layer.path = self.path.cgPath
            layer.strokeColor = SettingsManager.markerColor.cgColor
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = kCALineCapRound
            layer.lineJoin = kCALineJoinRound
            layer.lineWidth = 6
            self.layer.addSublayer(layer)
            self.markerLayer = layer
        case .changed:
            self.path.lineCapStyle = .round
            self.path.addLine(to: p)
            self.markerLayer?.path = self.path.cgPath
        case .cancelled, .ended:
            self.path.removeAllPoints()
            self.markerLayer = nil
        case .failed, .possible:
            break
        }
    }

    private dynamic func handleTap() {
        self.endEditing(true)
    }
}
