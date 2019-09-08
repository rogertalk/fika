import Foundation

struct LocalChunk: PlayableChunk {
    let url: URL
    let attachments: [ChunkAttachment]
    let duration: Int
    let externalContentId: String?
    let externalPlays = 0
    let reactions: [Int64: String]
    let senderId: Int64
    let start: Int64
    let end: Int64
    let textSegments: [TextSegment]?
}
