import Foundation

protocol Account {
    var id: Int64 { get }
    var displayName: String { get }
    var imageURL: URL? { get }
    var location: String? { get }
    var sharingLocation: Bool { get }
    var timeZone: String? { get }
    var username: String? { get }
    var status: String { get }
}

extension Account {
    var isActive: Bool {
        return self.status == "active" || self.isBot
    }

    var isBot: Bool {
        return self.status == "bot"
    }

    var isCurrentUser: Bool {
        guard let currentUserId = BackendClient.instance.session?.id else {
            return false
        }
        return self.id == currentUserId
    }

    var localTime: Date? {
        guard let name = self.timeZone else {
            return nil
        }
        return Date().forTimeZone(name)!
    }

    var sharingLocation: Bool {
        return self.location != nil
    }
}
