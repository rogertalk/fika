import UIKit

class DrawableView: UIView, Drawable {
    func draw(into context: CGContext) {
        DispatchQueue.main.sync {
            UIGraphicsPushContext(context)
            self.drawHierarchy(in: self.frame, afterScreenUpdates: false)
            UIGraphicsPopContext()
        }
        // Draw any subviews that happen to be Drawables.
        context.saveGState()
        context.translateBy(x: self.frame.origin.x, y: self.frame.origin.y)
        for view in self.subviews {
            guard let drawable = view as? Drawable, !drawable.isHidden else {
                continue
            }
            drawable.draw(into: context)
        }
        context.restoreGState()
    }
}
