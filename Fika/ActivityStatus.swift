enum ActivityStatus: String {
    case idle = "idle"
    case playing = "playing"
    case recording = "recording"
}

// The order in which statuses take precendence (for display purposes).
private let statusPriority: [ActivityStatus] = [.idle, .playing, .recording]
extension ActivityStatus: Comparable {}
func <(a: ActivityStatus, b: ActivityStatus) -> Bool {
    return statusPriority.index(of: a)! < statusPriority.index(of: b)!
}
