import Foundation

struct Chunk: PlayableChunk {
    static let dislikeReaction = "👎"
    static let likeReaction = "👍"

    let streamId: Int64
    let id: Int64
    let url: URL
    let attachments: [ChunkAttachment]
    let duration: Int
    let externalContentId: String?
    let externalPlays: Int
    let reactions: [Int64: String]
    let senderId: Int64
    let start: Int64
    let end: Int64
    let textSegments: [TextSegment]?

    init(streamId: Int64, data: DataType) {
        self.streamId = streamId
        self.id = (data["id"] as! NSNumber).int64Value
        self.url = URL(string: data["url"] as! String)!
        self.attachments = (data["attachments"] as? [DataType])?.map(ChunkAttachment.init) ?? []
        self.duration = data["duration"] as! Int
        self.externalContentId = data["external_content_id"] as? String
        self.externalPlays = data["external_plays"] as! Int
        self.senderId = (data["sender_id"] as! NSNumber).int64Value
        self.start = (data["start"] as! NSNumber).int64Value
        self.end = (data["end"] as! NSNumber).int64Value

        var reactions = [Int64: String]()
        if let reactionsData = data["reactions"] as? NSDictionary {
            for (id, reaction) in reactionsData {
                guard
                    let id = (id as? String).flatMap({ Int64($0) }),
                    let reaction = reaction as? String
                    else { continue }
                reactions[id] = reaction
            }
        }
        self.reactions = reactions

        // Avoid bridging a list of dictionaries as it's very expensive.
        if let list = data["text"] as? NSArray {
            var segments = [TextSegment]()
            var start = 0
            for i in stride(from: 0, to: list.count, by: 3) {
                start += list[i] as! Int
                let duration = list[i + 1] as! Int
                segments.append(TextSegment(start: start, duration: duration, text: list[i + 2] as! String))
                start += duration
            }
            self.textSegments = segments
        } else {
            self.textSegments = nil
        }
    }
}

extension Chunk: Equatable {
    static func ==(lhs: Chunk, rhs: Chunk) -> Bool {
        return lhs.streamId == rhs.streamId && lhs.id == rhs.id
    }
}
