import AVFoundation

class AudioService {
    static let instance = AudioService()

    /// The microphone to use. Note that an external microphone will take precedence.
    var microphone = Microphone.ignore {
        didSet {
            self.updateRoutes()
        }
    }

    var useLoudspeaker = false {
        didSet {
            guard self.useLoudspeaker != oldValue else { return }
            self.updateRoutes()
        }
    }

    var usingInternalMicrophone: Bool {
        return AVAudioSession.sharedInstance().currentRoute.inputs.contains {
            $0.portType == AVAudioSessionPortBuiltInMic
        }
    }

    var usingInternalSpeaker: Bool {
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == AVAudioSessionPortBuiltInReceiver || $0.portType == AVAudioSessionPortBuiltInSpeaker
        }
    }

    func updateRoutes() {
        let audio = AVAudioSession.sharedInstance()
        self.queue.async {
            // Ensure that we have a valid audio session.
            if audio.category != AVAudioSessionCategoryPlayAndRecord {
                do {
                    // TODO: Use .allowBluetoothA2DP option for playback and .allowBluetooth for recording. This fixes quality + device compatibility issues.
                    // Currently "updateRoutes" is called constantly. This needs to be fixed before the proper routes can be used.
                    try audio.setCategory(AVAudioSessionCategoryPlayAndRecord, with: [.mixWithOthers, .allowBluetooth])
                    try audio.setActive(true, with: .notifyOthersOnDeactivation)
                    NSLog("%@", "Activated PlayAndRecord audio session")
                } catch {
                    NSLog("%@", "WARNING: Failed to update audio session: \(error)")
                }
            }
            // Prefer the loudspeaker over the earpiece.
            // TODO: Don't override unless necessary.
            do {
                try audio.overrideOutputAudioPort(self.usingInternalSpeaker && self.useLoudspeaker ? .speaker : .none)
            } catch {
                NSLog("%@", "WARNING: Failed to override audio port: \(error)")
            }
            // Update the microphone orientation.
            if
                self.usingInternalMicrophone,
                let orientation = self.microphone.orientation,
                let mic = audio.inputDataSources?.first(where: {
                    if let o = $0.orientation {
                        return o == orientation
                    } else {
                        return false
                    }
                }),
                audio.inputDataSource != mic
            {
                do {
                    try audio.setInputDataSource(mic)
                } catch {
                    NSLog("%@", "WARNING: Failed to use \(orientation) microphone: \(error)")
                }
            }
        }
    }

    // MARK: - Private

    private let queue = DispatchQueue(label: "io.fika.Fika.AudioService")

    private init() {
        // Monitor changes to audio session.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(AudioService.audioSessionInterruption), name: .AVAudioSessionInterruption, object: nil)
        center.addObserver(self, selector: #selector(AudioService.audioSessionMediaServicesWereReset), name: .AVAudioSessionMediaServicesWereReset, object: nil)
        center.addObserver(self, selector: #selector(AudioService.audioSessionRouteChange), name: .AVAudioSessionRouteChange, object: nil)
    }

    private dynamic func audioSessionInterruption(notification: NSNotification) {
        let info = notification.userInfo!
        let type = AVAudioSessionInterruptionType(rawValue: info[AVAudioSessionInterruptionTypeKey] as! UInt)!
        switch type {
        case .began:
            NSLog("Audio session interrupted")
        case .ended:
            let options = AVAudioSessionInterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as! UInt)
            NSLog("%@", "Audio session interruption ended (shouldResume: \(options.contains(.shouldResume)))")
            self.updateRoutes()
        }
    }

    private dynamic func audioSessionRouteChange(notification: NSNotification) {
        let info = notification.userInfo!
        let reason = AVAudioSessionRouteChangeReason(rawValue: info[AVAudioSessionRouteChangeReasonKey] as! UInt)!
        NSLog("%@", "Audio session route change (\(reason))")
        self.updateRoutes()
    }

    private dynamic func audioSessionMediaServicesWereReset(notification: NSNotification) {
        NSLog("WARNING: Audio session media services were reset")
    }
}
