import CoreVideo
import QuartzCore

protocol Drawable: class {
    var frame: CGRect { get set }
    var isHidden: Bool { get set }
    func covers(_ rect: CGRect) -> Bool
    func draw(into context: CGContext)
}

extension Drawable {
    func covers(_ rect: CGRect) -> Bool {
        return self.frame.contains(rect)
    }
}
