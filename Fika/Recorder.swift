import AVFoundation
import Speech
import UIKit

class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, MediaWriterDelegate {

    static let instance = Recorder()

    enum Configuration {
        case audioOnly, backCamera, frontCamera
    }

    enum State {
        case idle, previewing, recording
    }

    let previewLayer: AVCaptureVideoPreviewLayer

    /// Emitted whenever recording becomes unavailable to the app (e.g., background, split screen).
    let recorderUnavailable = Event<AVCaptureSessionInterruptionReason>()

    private(set) var audioLevel = Float(0)

    var configuration = Configuration.frontCamera {
        didSet {
            guard self.state != .idle else { return }
            self.queue.async { self.configureDevice() }
        }
    }

    var currentZoom: CGFloat? {
        guard let camera = self.currentCamera?.device else {
            return nil
        }
        return camera.videoZoomFactor
    }

    /// An array of layers to draw into each video frame.
    /// The layer at index 0 is the back-most layer.
    var drawables = [Drawable]()

    var hasVideoContent: Bool {
        return self.drawables.count > 0
    }

    private(set) var state = State.idle

    override init() {
        // TODO: Consider exposing preview layer through a method instead.
        self.previewLayer = AVCaptureVideoPreviewLayer(session: self.capture)
        self.previewLayer.anchorPoint = .zero
        self.previewLayer.actions = ["bounds": NSNull()]
        self.previewLayer.backgroundColor = UIColor.black.cgColor
        self.previewLayer.masksToBounds = true
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill
        super.init()
        // Route the audio to the capture session.
        self.capture.usesApplicationAudioSession = true
        self.capture.automaticallyConfiguresApplicationAudioSession = false
        self.capture.addOutput(self.audioOutput)
        self.capture.addOutput(self.videoOutput)
        self.audioOutput.setSampleBufferDelegate(self, queue: self.queue)
        self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: Int32(kCVPixelFormatType_32BGRA))]
        self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
        // Monitor interruptions to video capture.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(Recorder.captureSessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: nil)
        center.addObserver(self, selector: #selector(Recorder.captureSessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: nil)
        center.addObserver(self, selector: #selector(Recorder.captureSessionInterruptionEnded), name: .AVCaptureSessionInterruptionEnded, object: nil)
        center.addObserver(self, selector: #selector(Recorder.updateOrientationOfAll), name: .UIApplicationDidChangeStatusBarOrientation, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        self.writer?.cancel()
        // Ensure that we're not keeping a lock on the camera.
        self.configureDevice(camera: nil, microphone: .ignore)
    }

    /// Aborts a recording.
    func cancelRecording() {
        precondition(self.state == .recording, "invalid state transition")
        self.state = .previewing
        self.queue.async {
            guard let writer = self.writer else {
                preconditionFailure("there was no writer")
            }
            self.writer = nil
            self.recognizer?.cancel()
            self.recognizer = nil
            writer.cancel()
            self.configureDevice()
        }
    }

    func drawables(for writer: MediaWriter) -> [Drawable] {
        // TODO: Implement a data flow where Recorder doesn't know about CameraView.
        if let drawable = self.fullScreenDrawable, drawable is CameraView {
            // The top drawable can be rendered by forwarding a pixel buffer instead.
            return []
        }
        return self.drawables
    }

    func focus(point: CGPoint) {
        guard let camera = self.currentCamera?.device, camera.isFocusPointOfInterestSupported else {
            return
        }
        camera.focusPointOfInterest = point
        camera.focusMode = .autoFocus
    }

    /// Starts capturing input from the currently configured devices (but not writing).
    func startPreviewing() {
        precondition(self.state == .idle, "invalid state transition")
        self.state = .previewing
        self.queue.async {
            self.configureDevice()
        }
    }

    /// Starts recording input to disk.
    func startRecording(locale: Locale? = nil) {
        precondition(self.state == .previewing, "invalid state transition")
        self.state = .recording
        self.queue.async {
            self.configureDevice()
            // Add a speech recognizer that will transcribe the audio.
            let recognizer = SpeechRecognizer(locale: locale)
            self.recognizer = recognizer

            // Set up the recording destination.
            let writer = MediaWriter(url: URL.temporaryFileURL("mp4"), clock: self.capture.masterClock, quality: .medium)
            writer.delegate = self

            // Start writing.
            self.startTime = Date()
            self.writer = writer
            if !writer.start() {
                NSLog("WARNING: Failed to start writing recording")
                self.cancelRecording()
            }
        }
    }

    /// Stops all capturing.
    func stopPreviewing() {
        precondition(self.state == .previewing, "invalid state transition")
        self.state = .idle
        self.queue.async {
            self.configureDevice(camera: nil, microphone: .ignore)
            self.capture.stopRunning()
        }
    }

    /// Stops recording input and calls the callback when done writing to disk.
    func stopRecording(callback: @escaping (Recording) -> Void) {
        precondition(self.state == .recording, "invalid state transition")
        self.state = .previewing
        self.queue.async {
            guard let writer = self.writer else {
                preconditionFailure("there was no writer")
            }
            self.writer = nil
            // Create a recording which holds all the relevant information for the recorded media.
            let duration = Date().timeIntervalSince(self.startTime)
            let promise: Promise<[TextSegment]>
            if let recognizer = self.recognizer {
                promise = recognizer.finish().then {
                    $0.bestTranscription.segments.map(TextSegment.init)
                }
                self.recognizer = nil
            } else {
                promise = Promise.reject(NSError(domain: "io.fika.Fika", code: -1))
            }
            let recording = Recording(duration: duration, fileURL: writer.url, transcript: promise)
            writer.finish {
                callback(recording)
            }
            self.configureDevice()
        }
    }

    func zoom(to factor: CGFloat) {
        guard let camera = self.currentCamera?.device else {
            return
        }
        camera.videoZoomFactor = max(1, min(factor, camera.activeFormat.videoMaxZoomFactor))
    }

    // MARK: - Private

    private lazy var audio: AVCaptureDeviceInput? = self.input(AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeAudio))
    private lazy var back: AVCaptureDeviceInput? = self.input(AVCaptureDevice.defaultDevice(withDeviceType: .builtInWideAngleCamera, mediaType: AVMediaTypeVideo, position: .back))
    private lazy var front: AVCaptureDeviceInput? = self.input(AVCaptureDevice.defaultDevice(withDeviceType: .builtInWideAngleCamera, mediaType: AVMediaTypeVideo, position: .front))
    private var currentCamera: AVCaptureDeviceInput?

    private let audioOutput = AVCaptureAudioDataOutput()
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.fika.Fika.Recorder", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()

    private var addedAudio = false
    private var cameraLocked = false

    /// If a single drawable is covering the entire screen, this property returns it.
    private var fullScreenDrawable: Drawable? {
        var i = self.drawables.count - 1
        while i >= 0 && self.drawables[i].isHidden {
            i -= 1
        }
        guard i >= 0 else { return nil }
        let drawable = self.drawables[i]
        guard drawable.covers(UIScreen.main.bounds) else {
            return nil
        }
        return drawable
    }

    private var recognizer: SpeechRecognizer?
    private var startTime = Date.distantFuture
    private var writer: MediaWriter?

    private dynamic func captureSessionRuntimeError(notification: NSNotification) {
        if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error {
            NSLog("WARNING: Capture session runtime error: \(error)")
        } else {
            NSLog("WARNING: Unknown capture session runtime error occurred")
        }
    }

    private dynamic func captureSessionWasInterrupted(notification: NSNotification) {
        guard
            let rawReason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
            let reason = AVCaptureSessionInterruptionReason(rawValue: rawReason)
            else
        {
            NSLog("WARNING: Failed to get interruption reason (\(notification.userInfo ?? [:]))")
            return
        }
        switch reason {
        case .audioDeviceInUseByAnotherClient:
            NSLog("WARNING: Capture session interrupted (audio in use by another client)")
        case .videoDeviceInUseByAnotherClient:
            NSLog("WARNING: Capture session interrupted (video in use by another client)")
        case .videoDeviceNotAvailableInBackground:
            NSLog("WARNING: Capture session interrupted (can't record video in background)")
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            NSLog("WARNING: Capture session interrupted (video not available with multiple apps)")
        }
        self.recorderUnavailable.emit(reason)
    }

    private dynamic func captureSessionInterruptionEnded(notification: NSNotification) {
        guard self.state != .idle else {
            return
        }
        self.queue.async {
            self.configureDevice()
        }
    }

    private func configureDevice() {
        switch self.configuration {
        case .audioOnly:
            self.configureDevice(camera: nil, microphone: .bottom)
        case .backCamera:
            self.configureDevice(camera: self.back, microphone: .front)
        case .frontCamera:
            self.configureDevice(camera: self.front, microphone: .front)
        }
    }

    private func configureDevice(camera: AVCaptureDeviceInput?, microphone: Microphone) {
        self.capture.beginConfiguration()
        // Add audio when necessary, but only attempt it once.
        if !self.addedAudio {
            if let audio = self.audio, self.capture.canAddInput(audio) {
                self.capture.addInput(audio)
                self.addedAudio = true
            } else {
                NSLog("WARNING: Failed to add audio input")
            }
        }
        let cameraChanged = self.currentCamera !== camera
        // Stop capturing input from the previous camera if it changed.
        if cameraChanged, let input = self.currentCamera {
            self.capture.removeInput(input)
            if self.cameraLocked {
                input.device.unlockForConfiguration()
                self.cameraLocked = false
            }
        }
        self.currentCamera = camera
        if self.state != .recording {
            // Set up the audio route.
            AudioService.instance.microphone = microphone
        }
        // Configure the selected camera.
        guard let input = camera else {
            // There is no camera (audio only).
            self.capture.commitConfiguration()
            self.startCapture()
            return
        }
        if cameraChanged {
            // Lock the camera so we can update its properties.
            precondition(!self.cameraLocked, "camera shouldn't be locked")
            do {
                try input.device.lockForConfiguration()
                self.cameraLocked = true
                // Configure the camera for 30 FPS.
                input.device.activeVideoMinFrameDuration = CMTimeMake(1, 30)
                input.device.activeVideoMaxFrameDuration = CMTimeMake(1, 30)
            } catch {
                NSLog("%@", "WARNING: Failed to lock camera for configuration: \(error)")
            }
            // Set up data input.
            if self.capture.canAddInput(input) {
                self.capture.addInput(input)
                if let connection = self.videoOutput.connection(withMediaType: AVMediaTypeVideo) {
                    connection.isVideoMirrored = self.configuration == .frontCamera
                } else {
                    NSLog("WARNING: Video output had no capture connection for video")
                }
            } else {
                NSLog("WARNING: Failed to set up camera")
            }
        }
        // Disable continuous autofocus while recording.
        if self.cameraLocked && input.device.isFocusModeSupported(.continuousAutoFocus) {
            input.device.focusMode = self.state == .recording ? .locked : .continuousAutoFocus
        }
        self.capture.commitConfiguration()
        self.startCapture()
        self.updateOrientationOfAll()
    }

    private func input(_ device: AVCaptureDevice?) -> AVCaptureDeviceInput? {
        guard let device = device else { return nil }
        return try? AVCaptureDeviceInput(device: device)
    }

    private func startCapture() {
        guard self.state != .idle else {
            return
        }
        if !self.capture.isRunning {
            self.capture.startRunning()
        }
        if !self.capture.isRunning {
            NSLog("%@", "WARNING: Failed to start capture session (\(self.capture.isInterrupted ? "interrupted" : "not interrupted"))")
        }
    }

    private func updateAudioLevel(sampleBuffer: CMSampleBuffer) {
        var buffer: CMBlockBuffer? = nil

        // Needs to be initialized somehow, even if we take only the address.
        var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            nil,
            &audioBufferList,
            MemoryLayout<AudioBufferList>.size,
            nil,
            nil,
            UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            &buffer)

        guard let audioBuffer = UnsafeMutableAudioBufferListPointer(&audioBufferList).first else {
            return
        }

        let samples = UnsafeMutableBufferPointer<Int16>(
            start: audioBuffer.mData?.assumingMemoryBound(to: Int16.self),
            count: Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size)

        guard samples.count > 0 else {
            return
        }

        self.audioLevel = sqrtf(samples.reduce(0) { $0 + powf(Float($1), 2) } / Float(samples.count))
    }

    private dynamic func updateOrientation(of connection: AVCaptureConnection) {
        switch UIApplication.shared.statusBarOrientation {
        case .landscapeLeft:
            connection.videoOrientation = .landscapeLeft
        case .landscapeRight:
            connection.videoOrientation = .landscapeRight
        case .portrait:
            connection.videoOrientation = .portrait
        case .portraitUpsideDown:
            connection.videoOrientation = .portraitUpsideDown
        default:
            break
        }
    }

    private dynamic func updateOrientationOfAll() {
        if let connection = self.videoOutput.connection(withMediaType: AVMediaTypeVideo) {
            self.updateOrientation(of: connection)
        }
        if let connection = self.previewLayer.connection {
            self.updateOrientation(of: connection)
        }
    }

    // MARK: - AVCapture{Audio,Video}DataOutputSampleBufferDelegate

    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        switch captureOutput {
        case self.audioOutput:
            self.updateAudioLevel(sampleBuffer: sampleBuffer)
            self.recognizer?.request.appendAudioSampleBuffer(sampleBuffer)
            self.writer?.appendAudio(sampleBuffer)
        case self.videoOutput:
            // TODO: Don't reference CameraView here.
            if let drawable = self.fullScreenDrawable, drawable is CameraView {
                // Simply forward pixel buffer to the writer instead.
                self.writer?.appendVideo(sampleBuffer)
            } else {
                guard self.state == .recording else {
                    return
                }
                for drawable in self.drawables {
                    // TODO: Don't reference CameraView here.
                    guard let input = drawable as? CameraView else {
                        continue
                    }
                    input.appendVideo(sampleBuffer)
                }
            }
        default:
            preconditionFailure("unknown capture output: \(captureOutput)")
        }
    }
}
