import AVFoundation
import UIKit

protocol MediaWriterDelegate: class {
    var hasVideoContent: Bool { get }
    func drawables(for writer: MediaWriter) -> [Drawable]
}

class MediaWriter {
    weak var delegate: MediaWriterDelegate?

    /// The local file URL that the video will be written to.
    var url: URL {
        return self.asset.outputURL
    }

    init(url: URL, clock: CMClock, quality: MediaWriterSettings.Quality = .medium) {
        self.clock = clock

        let settings: MediaWriterSettings
        switch UIApplication.shared.statusBarOrientation {
        case .landscapeLeft, .landscapeRight:
            settings = MediaWriterSettings(quality: quality, portrait: false)
        default:
            settings = MediaWriterSettings(quality: quality, portrait: true)
        }

        let scale = UIScreen.main.scale
        let size = UIScreen.main.bounds
        self.transform = CGAffineTransform(scaleX: scale, y: -scale).translatedBy(x: 0, y: -size.height)

        self.asset = try! AVAssetWriter(url: url, fileType: AVFileTypeMPEG4)
        // FIXME: We need these properties, but they currently break the recording.
        //self.asset.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 1000000000)
        //self.asset.shouldOptimizeForNetworkUse = true

        self.audio = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: settings.audioSettings)
        self.audio.expectsMediaDataInRealTime = true
        self.asset.add(self.audio)

        self.video = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: settings.videoSettings)
        self.video.expectsMediaDataInRealTime = true
        self.asset.add(self.video)

        let screenPixels = size.applying(CGAffineTransform(scaleX: scale, y: scale))
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: Int32(kCVPixelFormatType_32BGRA)),
            kCVPixelBufferWidthKey as String: screenPixels.width,
            kCVPixelBufferHeightKey as String: screenPixels.height,
            ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: self.video, sourcePixelBufferAttributes: attributes)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer), self.audio.isReadyForMoreMediaData else {
            return
        }
        if !self.writerSessionStarted {
            if let delegate = self.delegate, delegate.hasVideoContent {
                // Wait for video before writing any audio (because audio may arrive much sooner than video).
                return
            }
            // We won't render any video so the audio buffer may be used to initiate the writer session.
            self.ensureSessionStarted(buffer: sampleBuffer)
        }
        self.audio.append(sampleBuffer)
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        self.appendFramePixelBufferQueue.sync {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            self.safelyAppendVideo(buffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
    }

    func cancel() {
        if let displayLink = self.displayLink {
            displayLink.invalidate()
            self.displayLink = nil
        }
        // TODO: Delete temporary file.
        self.asset.cancelWriting()
    }

    func finish(callback: @escaping () -> ()) {
        if let displayLink = self.displayLink {
            displayLink.invalidate()
            self.displayLink = nil
        }
        self.frameRenderQueue.async {
            self.appendFramePixelBufferQueue.async {
                // Clean up and complete writing.
                self.audio.markAsFinished()
                self.video.markAsFinished()
                self.asset.finishWriting {
                    if self.asset.status != .completed {
                        NSLog("%@", "WARNING: Asset writer finished with status \(self.asset.status.rawValue)")
                        if let error = self.asset.error {
                            NSLog("%@", "WARNING: Asset writer error: \(error)")
                        }
                    }
                    // Let the UI know as soon as the file is ready.
                    callback()
                }
            }
        }
    }

    func start() -> Bool {
        let displayLink = CADisplayLink(target: self, selector: #selector(MediaWriter.renderVideoFrame))
        self.displayLink = displayLink
        displayLink.add(to: RunLoop.main, forMode: .commonModes)
        return self.asset.startWriting()
    }

    // MARK: - Private

    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let appendFramePixelBufferQueue = DispatchQueue(label: "io.fika.Fika.AppendFramePixelBufferQueue")
    private let appendFramePixelBufferSemaphore = DispatchSemaphore(value: 1)
    private let asset: AVAssetWriter
    private let audio, video: AVAssetWriterInput
    private let clock: CMClock
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let frameRenderQueue = DispatchQueue(label: "io.fika.Fika.FrameRenderQueue", qos: .userInteractive)
    private let frameRenderSemaphore = DispatchSemaphore(value: 1)
    private let minDelta = CMTime(value: 15000000, timescale: 1000000000)
    private let transform: CGAffineTransform

    private var displayLink: CADisplayLink?
    private var lastVideoTimestamp = CMTime(value: 0, timescale: 1)
    private var latestVideoImage: CGImage?
    private var latestVideoImageContext: CGContext?
    private var writerSessionStarted = false

    private func createPixelBuffer() -> CVPixelBuffer? {
        guard let pool = self.adaptor.pixelBufferPool else {
            return nil
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func ensureSessionStarted(buffer sampleBuffer: CMSampleBuffer) {
        self.ensureSessionStarted(time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func ensureSessionStarted(time: CMTime) {
        guard !self.writerSessionStarted else {
            return
        }
        self.asset.startSession(atSourceTime: time)
        self.writerSessionStarted = true
    }

    private dynamic func renderVideoFrame() {
        guard
            let drawables = self.delegate?.drawables(for: self).filter({ !$0.isHidden }),
            !drawables.isEmpty,
            self.video.isReadyForMoreMediaData,
            self.frameRenderSemaphore.waitOrFail()
            else { return }

        self.frameRenderQueue.async {
            let timestamp = CMClockGetTime(self.clock)

            // Create the buffer that everything will be composited into.
            guard let buffer = self.createPixelBuffer() else {
                self.frameRenderSemaphore.signal()
                return
            }

            CVPixelBufferLockBaseAddress(buffer, [])

            guard let context = CGContext.create(with: buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                self.frameRenderSemaphore.signal()
                return
            }

            context.saveGState()
            context.concatenate(self.transform)

            // First scan downwards until we hit a drawable that covers everything below it.
            var start = drawables.count - 1
            while start > 0 {
                if drawables[start].covers(UIScreen.main.bounds) {
                    break
                }
                start -= 1
            }
            // Render the drawables upwards.
            for i in start..<drawables.count {
                if drawables[i].frame.isEmpty {
                    continue
                }
                context.saveGState()
                drawables[i].draw(into: context)
                context.restoreGState()
            }

            context.restoreGState()

            // Proceed only if the append queue is ready, otherwise unlock the pixel buffer.
            // The next frame can be rendered while this one is being appended.
            guard self.appendFramePixelBufferSemaphore.waitOrFail() else {
                self.frameRenderSemaphore.signal()
                CVPixelBufferUnlockBaseAddress(buffer, [])
                return
            }

            self.appendFramePixelBufferQueue.async {
                self.safelyAppendVideo(buffer, timestamp: timestamp)
                CVPixelBufferUnlockBaseAddress(buffer, [])
                // NOTE: For 60 FPS, this signal could be moved to before this block.
                self.frameRenderSemaphore.signal()
                self.appendFramePixelBufferSemaphore.signal()
            }
        }
    }

    @discardableResult
    private func safelyAppendVideo(_ buffer: CVPixelBuffer, timestamp: CMTime) -> Bool {
        guard self.video.isReadyForMoreMediaData else {
            NSLog("%@", "WARNING: Dropped a video frame because writer was not ready")
            return false
        }
        guard timestamp - self.minDelta > self.lastVideoTimestamp else {
            NSLog("%@", "WARNING: Dropped a video frame due to negative/low time delta")
            return false
        }
        self.ensureSessionStarted(time: timestamp)
        if !self.adaptor.append(buffer, withPresentationTime: timestamp) {
            // TODO: Check the asset writer status and notify if it failed.
            NSLog("%@", "WARNING: Failed to append a frame to pixel buffer adaptor")
            return false
        }
        self.lastVideoTimestamp = timestamp
        return true
    }
}
