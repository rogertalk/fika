import Foundation

private let currentSessionVersion = 4

private func getAccountId(_ data: DataType) -> Int64? {
    guard let account = data["account"] as? DataType, let id = account["id"] as? NSNumber else {
        return nil
    }
    return id.int64Value
}

struct Session: Account {
    let data: DataType

    var accessToken: String {
        return self.data["access_token"] as! String
    }

    let account: [String: Any]

    var didSetDisplayName: Bool {
        return self.account["display_name_set"] as? Bool ?? true
    }

    var displayName: String {
        return self.remoteDisplayName
    }

    var expires: Date {
        let ttl = (self.data["expires_in"] as! NSNumber).intValue
        return Date(timeIntervalSinceNow: TimeInterval(ttl))
    }

    var hasLocation: Bool {
        return self.isSharingLocation && self.location != nil
    }

    let id: Int64

    var isActive: Bool {
        return self.data["status"] as! String == "active"
    }

    var identifiers: [String]? {
        if let identifiers = self.account["aliases"] as? [String] {
            return identifiers
        }
        return self.account["identifiers"] as? [String]
    }

    var imageURL: URL? {
        guard let urlString = self.account["image_url"] as? String else {
            return nil
        }
        return URL(string: urlString)
    }

    var isPremium: Bool {
        return self.account["premium"] as? Bool ?? false
    }

    var isSharingLocation: Bool {
        return self.account["share_location"] as? Bool ?? false
    }

    var location: String? {
        return self.account["location"] as? String
    }

    var refreshToken: String? {
        return self.data["refresh_token"] as? String
    }

    var remoteDisplayName: String {
        return self.account["display_name"] as! String
    }

    let services: [ConnectedService]

    var status: String {
        return self.data["status"] as! String
    }

    var teamDomain: String? {
        guard let service = self.services.first, service.id == "email", let team = service.team else {
            return nil
        }
        return team.id
    }

    let timestamp: Date

    var timeZone: String? {
        // TODO: Ideally we'll make this value never nil.
        return self.account["timezone"] as? String
    }

    var username: String? {
        return self.account["username"] as? String
    }

    static func clearUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "session")
        defaults.removeObject(forKey: "sessionTimestamp")
        defaults.removeObject(forKey: "sessionRefreshToken")
        defaults.removeObject(forKey: "sessionVersion")
    }

    static func fromUserDefaults() -> Session? {
        // Attempt to get the session data out of the user defaults.
        // TODO: This should be deprecated in favor of Keychain Services.
        let defaults = UserDefaults.standard
        let session = defaults.object(forKey: "session")
        guard let archivedData = session as? Data else {
            return nil
        }
        var data = NSKeyedUnarchiver.unarchiveObject(with: archivedData) as! DataType
        let timestamp = (defaults.object(forKey: "sessionTimestamp") as? Date) ?? Date()
        // Ensure the session is of a compatible version or upgrade it.
        let version = defaults.integer(forKey: "sessionVersion")
        switch version {
        case 2:
            var accountData = data["account"] as! DataType
            accountData["services"] = [DataType]()
            data["account"] = accountData
            return Session(data, timestamp: timestamp)
        case 3:
            var accountData = data["account"] as! DataType
            var servicesData = accountData["services"] as! [DataType]
            for (i, _) in servicesData.enumerated() {
                guard var teamData = servicesData[i]["team"] as? DataType else {
                    continue
                }
                teamData["resource"] = ""
                servicesData[i]["team"] = teamData
            }
            accountData["services"] = servicesData
            data["account"] = accountData
            return Session(data, timestamp: timestamp)
        case currentSessionVersion:
            return Session(data, timestamp: timestamp)
        default:
            NSLog("%@", "WARNING: Tried to load session with unsupported defaults version \(version)")
            return nil
        }
    }

    init?(_ data: DataType, timestamp: Date) {
        self.data = data
        guard let id = getAccountId(data) else {
            self.id = -1
            return nil
        }
        self.id = id
        self.account = data["account"] as! DataType
        self.services = (self.account["services"] as! [DataType]).map(ConnectedService.init)
        self.timestamp = timestamp
    }

    func hasService(id: String) -> Bool {
        return self.services.contains(where: { $0.id == id })
    }

    func setUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(NSKeyedArchiver.archivedData(withRootObject: self.data), forKey: "session")
        defaults.set(self.timestamp, forKey: "sessionTimestamp")
        if let refreshToken = self.refreshToken {
            defaults.set(refreshToken, forKey: "sessionRefreshToken")
        }
        defaults.set(currentSessionVersion, forKey: "sessionVersion")
    }

    func withNewAccountData(_ accountData: DataType) -> Session? {
        var data = self.data
        data["account"] = accountData
        return Session(data, timestamp: self.timestamp)
    }
}
