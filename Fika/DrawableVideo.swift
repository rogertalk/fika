import CoreMedia
import UIKit

class DrawableVideo: Drawable {
    let scale: CGFloat

    var frame: CGRect = .zero {
        didSet {
            guard self.frame.size != oldValue.size else {
                return
            }
            self.configureContext()
        }
    }

    var isHidden = false

    init(scale: CGFloat) {
        pthread_mutex_init(&self.mutex, nil)
        self.scale = scale
    }

    deinit {
        pthread_mutex_destroy(&self.mutex)
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            NSLog("WARNING: Failed to get pixel buffer from CMSampleBuffer")
            return
        }
        self.appendVideo(pixelBuffer)
    }

    func appendVideo(_ buffer: CVPixelBuffer) {
        pthread_mutex_lock(&self.mutex)
        defer { pthread_mutex_unlock(&self.mutex) }
        guard let context = self.context else {
            return
        }
        guard CVPixelBufferLockBaseAddress(buffer, [.readOnly]) == kCVReturnSuccess else {
            NSLog("WARNING: Failed to lock CVPixelBuffer")
            return
        }
        guard let image = CGImage.create(with: buffer) else {
            NSLog("WARNING: Failed to create CGImage based on CVPixelBuffer")
            CVPixelBufferUnlockBaseAddress(buffer, [.readOnly])
            return
        }
        CVPixelBufferUnlockBaseAddress(buffer, [.readOnly])
        // Calculate the biggest rectangle with same aspect ratio as the video frame.
        let frame = self.frame
        let ratioW = CGFloat(image.width) / frame.width
        let ratioH = CGFloat(image.height) / frame.height
        let ratio = ratioW < ratioH ? ratioW : ratioH
        let width = Int(frame.width * ratio)
        let height = Int(frame.height * ratio)
        // Crop the rectangle from the center of the video frame.
        let crop = CGRect(x: (image.width - width) / 2, y: (image.height - height) / 2, width: width, height: height)
        guard let cropped = image.cropping(to: crop) else {
            return
        }
        // Draw the video image scaled into a context managed by us.
        // Releasing the previous image before touching the context
        // avoids a copy-on-write, saving both memory and CPU.
        self.image = nil
        context.draw(cropped, in: CGRect(origin: .zero, size: frame.size))
        guard let scaledImage = context.makeImage() else {
            return
        }
        // Store a reference to the most recent cropped video frame.
        self.image = scaledImage
    }

    func draw(into context: CGContext) {
        pthread_mutex_lock(&self.mutex)
        defer { pthread_mutex_unlock(&self.mutex) }
        guard let image = self.image else {
            return
        }
        context.draw(image, in: self.frame)
    }

    // MARK: - Private

    private var context: CGContext?
    private var image: CGImage?
    private var mutex = pthread_mutex_t()

    private func configureContext() {
        pthread_mutex_lock(&self.mutex)
        defer { pthread_mutex_unlock(&self.mutex) }
        let rect = self.frame.applying(CGAffineTransform(scaleX: self.scale, y: self.scale))
        guard !rect.isEmpty, let context = CGContext.create(size: rect.size) else {
            self.context = nil
            return
        }
        // Draw the old context into the new one to avoid black flicker.
        if let oldContext = self.context, let image = oldContext.makeImage() {
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        }
        // Apply scale and flip the Y axis so that
        // the context matches UI coordinate space.
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: self.scale, y: -self.scale)
        self.context = context
        self.image = context.makeImage()
    }
}
