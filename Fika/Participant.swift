import Foundation

class Participant: Account {
    let id: Int64
    private(set) var activityStatus = ActivityStatus.idle
    private(set) var activityStatusEnd = Date()

    var commonTeams: [ServiceIdentifier] {
        guard let ids = self.data["teams"] as? [String] else {
            return []
        }
        return ids.map { ServiceIdentifier(value: $0)! }
    }

    var displayName: String {
        return self.data["display_name"] as! String
    }

    var imageURL: URL? {
        if let url = self.data["image_url"] as? String {
            return URL(string: url)
        }
        return nil
    }

    var location: String? {
        return self.data["location"] as? String
    }

    var ownerId: Int64? {
        return (self.data["owner_id"] as? NSNumber)?.int64Value
    }

    /// The timestamp (in milliseconds since 1970) of the time up until which the participant has played the stream.
    var playedUntil: Int64 {
        return (self.data["played_until"] as! NSNumber).int64Value
    }

    var playedUntilDate: Date {
        return Date(timeIntervalSince1970: TimeInterval(self.playedUntil) / 1000)
    }

    /// The timestamp (in milliseconds since 1970) of when the participant most recently played an unplayed chunk.
    var playedUntilChanged: Int64 {
        return (self.data["played_until_changed"] as! NSNumber).int64Value
    }

    var playedUntilChangedDate: Date {
        return Date(timeIntervalSince1970: TimeInterval(self.playedUntilChanged) / 1000)
    }

    var status: String {
        return self.data["status"] as! String
    }

    var timeZone: String? {
        return self.data["timezone"] as? String
    }

    var username: String? {
        return self.data["username"] as? String
    }

    init(data: DataType) {
        self.data = data
        self.id = (data["id"] as! NSNumber).int64Value
    }

    /// Sets the status with an estimated duration.
    func update(activityStatus: ActivityStatus, duration: Int) {
        self.activityStatus = activityStatus
        self.activityStatusEnd = Date(timeIntervalSinceNow: Double(duration) / 1000)
    }

    /// Perform a local update to the played until timestamp.
    func update(playedUntil: Int64) {
        self.data["played_until"] = NSNumber(value: playedUntil)
        self.data["played_until_changed"] = NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000))
    }

    // MARK: Private

    private var data: DataType
}

// MARK: - Stream Equatable

extension Participant: Equatable {
    static func ==(lhs: Participant, rhs: Participant) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Participant Hashable

extension Participant: Hashable {
    var hashValue: Int {
        return self.id.hashValue
    }
}
