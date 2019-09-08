import AVFoundation
import UIKit

struct MediaWriterSettings {
    enum Quality {
        case medium
    }

    let quality: Quality
    let portrait: Bool

    var audioSettings: [String: Any] {
        let bitRate, sampleRate: Int
        switch self.quality {
        case .medium:
            bitRate = 64000
            sampleRate = 44100
        }
        return [
            AVNumberOfChannelsKey: NSNumber(value: 1),
            AVEncoderBitRatePerChannelKey: NSNumber(value: bitRate),
            AVFormatIDKey: NSNumber(value: kAudioFormatMPEG4AAC),
            AVSampleRateKey: NSNumber(value: sampleRate),
        ]
    }

    var videoSettings: [String: Any] {
        let bitRate: Int
        switch self.quality {
        case .medium:
            bitRate = 1572864
        }
        let width = (self.portrait ? 648 : 1152)
        let height = (self.portrait ? 1152 : 648)
        return [
            AVVideoCodecKey: AVVideoCodecH264,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: NSNumber(value: true),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High41,
                AVVideoMaxKeyFrameIntervalDurationKey: NSNumber(value: 1),
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: NSNumber(value: 30),
                AVVideoAverageBitRateKey: NSNumber(value: bitRate),
                "Priority": NSNumber(value: 80),
                "RealTime": NSNumber(value: true),
            ],
            AVVideoWidthKey: NSNumber(value: width),
            AVVideoHeightKey: NSNumber(value: height),
        ]
    }
}
