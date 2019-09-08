import Foundation

protocol SendableChunk {
    var attachments: [ChunkAttachment] { get }
    var url: URL { get }
    var duration: Int { get}
    var externalContentId: String? { get }
    var textSegments: [TextSegment]? { get }
    var token: String? { get }
}

extension SendableChunk {
    var token: String? {
        return nil
    }
}
