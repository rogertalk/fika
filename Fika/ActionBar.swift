import UIKit

protocol ActionBarDelegate: class {
    func actionBar(_ actionBar: ActionBar, action: ActionBar.Action, translation: CGPoint, state: UIGestureRecognizerState)
    func actionBar(_ actionBar: ActionBar, requestingAction action: ActionBar.Action)
}

class ActionBar: UIView {
    enum Action: String {
        case back
        case beginRecording, endRecording
        case markerOn, markerOff
        case presentImage, clearImage
        case presentWeb, clearWeb
        case text
        case useBackCamera, useFrontCamera
        case videoOn, videoOff
    }

    enum Alignment {
        case leading, center, trailing
    }

    /// The size of the action buttons.
    var buttonSize = CGSize(width: 50, height: 50) {
        didSet { self.layoutSubviews() }
    }

    weak var delegate: ActionBarDelegate?

    /// The actions to show in the action bar.
    var actions = [Action]() {
        didSet {
            self.layoutChange(from: oldValue, to: self.actions)
        }
    }

    var alignment = Alignment.center {
        didSet { self.layoutSubviews() }
    }

    /// Gets the action represented by the provided button (if it's currently visible).
    func action(for button: UIButton) -> Action? {
        guard let index = self.buttons.index(of: button) else {
            return nil
        }
        return self.actions[index]
    }

    /// Gets the button that represents the provided action (if it's currently visible).
    func button(for action: Action) -> UIButton? {
        guard let index = self.actions.index(of: action) else {
            return nil
        }
        return self.buttons[index]
    }

    // MARK: - UIView

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isOpaque = false
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard self.bounds.contains(point) else {
            return false
        }
        return self.subviews.contains {
            let localPoint = CGPoint(x: point.x - $0.frame.origin.x, y: point.y - $0.frame.origin.y)
            return $0.point(inside: localPoint, with: event)
        }
    }

    override func layoutSubviews() {
        self.layoutChange(from: self.actions, to: self.actions)
    }

    // MARK: - Private

    private var buttons = [UIButton]()

    private dynamic func buttonDragged(gestureRecognizer: UIPanGestureRecognizer) {
        guard let button = gestureRecognizer.view as? UIButton, let action = self.action(for: button) else {
            return
        }
        self.delegate?.actionBar(self, action: action, translation: gestureRecognizer.translation(in: button), state: gestureRecognizer.state)
    }

    private dynamic func buttonTapped(sender: UIButton) {
        guard let action = self.action(for: sender) else {
            return
        }
        self.delegate?.actionBar(self, requestingAction: action)
    }

    private func createButton(for action: Action) -> UIButton {
        // Set a material icon to use. Note that for toggle actions, we set the opposite icon to represent
        // the current state as opposed to the state you will get once you perform the action.
        var iconSize = CGFloat(28)

        let icon: String
        switch action {
        case .beginRecording, .endRecording:
            preconditionFailure("Don't use this method for the record button")
        case .back:
            icon = "keyboard_arrow_left"
        case .clearImage, .clearWeb:
            icon = "close"
        case .markerOff:
            icon = "border_color"
            iconSize = 24
        case .markerOn:
            icon = "mode_edit"
            iconSize = 24
        case .presentImage:
            icon = "photo"
        case .presentWeb:
            icon = "cloud"
        case .text:
            icon = "format_size"
        case .useBackCamera:
            icon = "camera_front"
        case .useFrontCamera:
            icon = "camera_rear"
        case .videoOff:
            icon = "videocam_off"
        case .videoOn:
            icon = "videocam"
        }

        let button = UIButton(type: .custom)
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.frame = CGRect(origin: CGPoint.zero, size: self.buttonSize)
        button.setTitle(icon, for: .normal)
        let label = button.titleLabel!
        label.font = UIFont.materialFont(ofSize: iconSize)
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(UIColor.white.withAlphaComponent(0.5), for: .highlighted)
        return button
    }

    private func layoutCenters(numButtons: Int) -> [CGPoint] {
        let width = self.buttonSize.width
        // Get the X coordinate of the middle of the leftmost button.
        let x: CGFloat
        switch self.alignment {
        case .center:
            x = self.bounds.width / 2 - width * (CGFloat(numButtons) / 2 - 0.5)
        case .leading:
            x = width / 2
        case .trailing:
            x = self.bounds.width - width * (CGFloat(numButtons) - 0.5)
        }
        return (0..<numButtons).map { CGPoint(x: x + width * CGFloat($0), y: self.bounds.midY) }
    }

    private func layoutChange(from: [Action], to: [Action]) {
        // TODO: Make sure there are no duplicates in from/to.
        let oldButtons = self.buttons
        let buttons: [UIButton] = to.map {
            if let prevIndex = from.index(of: $0) {
                return oldButtons[prevIndex]
            } else {
                return self.createButton(for: $0)
            }
        }

        self.buttons = buttons

        let centers = self.layoutCenters(numButtons: buttons.count)
        for (i, button) in buttons.enumerated() {
            if oldButtons.contains(button) {
                // The button was already there, move it to its new place.
                UIView.animate(withDuration: 0.2) { button.center = centers[i] }
                continue
            }
            // The button was just created, fade it in.
            button.alpha = 0
            self.addSubview(button)
            button.center = centers[i]
            button.addTarget(self, action: #selector(ActionBar.buttonTapped), for: .touchUpInside)
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(ActionBar.buttonDragged))
            button.addGestureRecognizer(recognizer)
            UIView.animate(withDuration: 0.2) { button.alpha = 1 }
        }

        for button in oldButtons {
            if buttons.contains(button) {
                continue
            }
            // The button was just removed, fade it out.
            button.removeTarget(self, action: #selector(ActionBar.buttonTapped), for: .touchUpInside)
            UIView.animate(
                withDuration: 0.2,
                animations: { button.alpha = 0 },
                completion: { _ in button.removeFromSuperview() })
        }
    }
}
