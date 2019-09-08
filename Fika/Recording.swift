import Foundation
import Speech

struct Recording {
    let duration: TimeInterval
    let fileURL: URL
    let transcript: Promise<[TextSegment]>
}
