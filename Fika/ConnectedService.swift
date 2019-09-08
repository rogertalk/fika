import Foundation

struct ConnectedService {
    struct Team {
        let data: DataType

        var id: String {
            return self.data["id"] as! String
        }

        var imageURL: URL? {
            guard let urlString = self.data["image_url"] as? String else {
                return nil
            }
            return URL(string: urlString)
        }

        var name: String {
            return self.data["name"] as! String
        }

        var resource: String {
            return self.data["resource"] as! String
        }
    }

    let data: DataType

    var id: String {
        return self.data["id"] as! String
    }

    var imageURL: URL? {
        guard let urlString = self.data["image_url"] as? String else {
            return nil
        }
        return URL(string: urlString)
    }

    var team: Team? {
        guard let data = self.data["team"] as? DataType else {
            return nil
        }
        return Team(data: data)
    }

    var title: String {
        return self.data["title"] as! String
    }

    init(_ data: DataType) {
        self.data = data
    }
}

extension ConnectedService: Equatable {
    static func ==(lhs: ConnectedService, rhs: ConnectedService) -> Bool {
        return lhs.id == rhs.id && lhs.team?.id == rhs.team?.id
    }
}
