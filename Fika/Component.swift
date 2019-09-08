import UIKit

/// A more advanced Drawable wrapping another Drawable. The
/// Component is represented by a UIView and uses the style
/// of the UIView when rendering the underlying Drawable.
class Component: UIView, Drawable {
    override var frame: CGRect {
        get { return self.drawable.frame }
        set {
            self.drawable.frame = newValue
            super.frame = newValue
        }
    }

    var hasShadow: Bool {
        guard let color = self.layer.shadowColor else {
            return false
        }
        let hasOffset = self.layer.shadowOffset.width != 0 || self.layer.shadowOffset.height != 0
        let alpha = CGFloat(self.layer.shadowOpacity) * color.alpha
        return alpha > 0 && (hasOffset || self.layer.shadowRadius > 0)
    }

    var path: CGPath {
        if self.layer.cornerRadius > 0 {
            return CGPath(roundedRect: self.frame,
                          cornerWidth: self.layer.cornerRadius,
                          cornerHeight: self.layer.cornerRadius,
                          transform: nil)
        } else {
            return CGPath(rect: self.frame, transform: nil)
        }
    }

    init(frame: CGRect, drawable: Drawable) {
        drawable.frame = frame
        self.drawable = drawable
        super.init(frame: frame)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func covers(_ rect: CGRect) -> Bool {
        // TODO: Transparency.
        // TODO: Technically, the frame may still be covering
        //       the rect when it has a corner radius.
        return self.frame.contains(rect) && self.layer.cornerRadius == 0
    }

    func draw(into context: CGContext) {
        if self.hasShadow, let color = self.layer.shadowColor {
            // TODO: Cache the shadow on frame size change instead of redrawing it every frame.
            context.addPath(self.path)
            // TODO: The scale should be based on the context's current transform.
            let scale = UIScreen.main.nativeScale
            context.setShadow(offset: self.layer.shadowOffset.applying(CGAffineTransform(scaleX: scale, y: -scale)),
                              blur: self.layer.shadowRadius * scale,
                              color: color.copy(alpha: color.alpha * CGFloat(self.layer.shadowOpacity)))
            context.fillPath()
        }
        if self.layer.cornerRadius > 0 {
            context.addPath(self.path)
            context.clip()
        }
        self.drawable.draw(into: context)
    }

    private let drawable: Drawable
}
