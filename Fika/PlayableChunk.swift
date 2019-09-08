import Foundation

protocol PlayableChunk: SendableChunk {
    var end: Int64 { get }
    var externalContentId: String? { get }
    var externalPlays: Int { get }
    var reactions: [Int64: String] { get }
    var senderId: Int64 { get }
    var start: Int64 { get }
    var textSegments: [TextSegment]? { get }
}

extension PlayableChunk {
    var age: TimeInterval {
        return Date().timeIntervalSince1970 - TimeInterval(self.end) / 1000
    }

    var byCurrentUser: Bool {
        return self.senderId == BackendClient.instance.session?.id
    }

    var endDate: Date {
        return Date(timeIntervalSince1970: TimeInterval(self.end) / 1000)
    }

    var externalContentURL: URL? {
        guard let id = self.externalContentId else {
            return nil
        }
        return SettingsManager.getExternalContentURL(for: id)
    }

    var transcript: String? {
        guard let segments = self.textSegments?.filter({ !$0.text.isEmpty }).map({ $0.text }), !segments.isEmpty else {
            return nil
        }
        return segments.joined(separator: " ")
    }

    var userReaction: String? {
        guard let id = BackendClient.instance.session?.id else {
            return nil
        }
        return self.reactions[id]
    }
}
