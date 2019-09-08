import UIKit

private enum SettingsKey: String {
    /// The ids of streams marked as favorites.
    case favorites
    /// The hue (color) of the marker in presentation mode.
    case markerHue
    /// Holds a list of streams for which notifications should not be displayed.
    case mutedStreams
    /// At what rate to play back content.
    case playbackRate
    // Flags for core actions that the user has performed.
    case playedChunk, sentChunk, setUpNotifications
    /// Whether to prefer playing through the loudspeaker (vs earpiece).
    case preferLoudspeaker
}

class SettingsManager {
    static var didPlayChunk: Bool {
        get { return getBool(.playedChunk) }
        set { set(.playedChunk, to: newValue) }
    }

    static var didSendChunk: Bool {
        get { return getBool(.sentChunk) }
        set { set(.sentChunk, to: newValue) }
    }

    static var didSetUpNotifications: Bool {
        get { return getBool(.setUpNotifications) }
        set { set(.setUpNotifications, to: newValue) }
    }

    static var favorites: [Int64] {
        get { return (get(.favorites) as? [Int64]) ?? [] }
        set { set(.favorites, to: newValue) }
    }

    static var markerColor: UIColor {
        return UIColor(hue: CGFloat(self.markerHue / 360), saturation: 1, brightness: 1, alpha: 1)
    }

    static var markerHue: Float {
        get { return getFloat(.markerHue) }
        set { set(.markerHue, to: newValue) }
    }

    static var playbackRate: Float {
        get { return max(getFloat(.playbackRate), 1) }
        set { set(.playbackRate, to: newValue) }
    }

    static var preferFrontCamera: Bool = true

    static var preferLoudspeaker: Bool {
        get { return getBool(.preferLoudspeaker) }
        set { set(.preferLoudspeaker, to: newValue) }
    }

    // MARK: Methods

    static func getExternalContentURL(for contentId: String) -> URL? {
        return URL(string: "https://watch.fika.io/-/\(contentId)")
    }

    static func isMuted(stream: Stream) -> Bool {
        return self.mutedStreams.keys.contains(NSNumber(value: stream.id))
    }

    static func mute(stream: Stream, until: Date) {
        self.mutedStreams[NSNumber(value: stream.id)] = until
    }

    @discardableResult
    static func toggleFavorite(streamId: Int64) -> [Int64] {
        var favorites = self.favorites
        if let index = favorites.index(of: streamId) {
            favorites.remove(at: index)
        } else {
            favorites.append(streamId)
        }
        self.favorites = favorites
        return favorites
    }

    static func unmute(stream: Stream) {
        self.mutedStreams.removeValue(forKey: NSNumber(value: stream.id))
    }

    static func updateMutedStreams() {
        let expired = self.mutedStreams.filter { $0.value <= Date() }
        expired.forEach {
            self.mutedStreams.removeValue(forKey: $0.key)
        }
    }

    // MARK: - Private

    private static var mutedStreams: [NSNumber: Date] {
        get {
            guard let data = get(.mutedStreams) as? Data else {
                return [:]
            }
            return NSKeyedUnarchiver.unarchiveObject(with: data) as? [NSNumber: Date] ?? [:]
        }
        set {
            let data = NSKeyedArchiver.archivedData(withRootObject: newValue)
            set(.mutedStreams, to: data)
        }
    }
}

private let defaults = UserDefaults.standard

private func get(_ key: SettingsKey) -> Any? {
    return defaults.object(forKey: key.rawValue)
}

private func getBool(_ key: SettingsKey) -> Bool {
    return defaults.bool(forKey: key.rawValue)
}

private func getFloat(_ key: SettingsKey) -> Float {
    return defaults.float(forKey: key.rawValue)
}

private func set(_ key: SettingsKey, to value: Any?) {
    defaults.set(value, forKey: key.rawValue)
}
