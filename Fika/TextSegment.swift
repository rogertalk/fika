import Speech

struct TextSegment {
    let data: DataType

    /// The duration of the segment in milliseconds.
    var duration: Int {
        return self.data["duration"] as! Int
    }

    /// The start of the segment in milliseconds relative to the start of the chunk.
    var start: Int {
        return self.data["start"] as! Int
    }

    var text: String {
        return self.data["text"] as! String
    }

    init(data: DataType) {
        self.data = data
    }

    init(start: Int, duration: Int, text: String) {
        self.data = ["duration": duration, "start": start, "text": text]
    }

    init(segment: SFTranscriptionSegment) {
        self.data = [
            "duration": Int(segment.duration * 1000),
            "start": Int(segment.timestamp * 1000),
            "text": segment.substring,
        ]
    }
}
