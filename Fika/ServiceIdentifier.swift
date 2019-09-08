import Foundation

fileprivate func decode(_ value: String) -> String? {
    return value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
}

fileprivate func encode(_ value: String) -> String? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: " _.-")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+")
}

struct ServiceIdentifier: CustomStringConvertible, Equatable {
    let service, resource: String
    let team: String?

    init(service: String, team: String?, resource: String) {
        self.service = service
        self.team = team
        self.resource = resource
    }

    init?(value: String) {
        let pieces = value.components(separatedBy: ":")
        guard pieces.count == 2 else {
            return nil
        }
        self.service = pieces[0]
        let teamAndResource = pieces[1].components(separatedBy: "/")
        if teamAndResource.count == 1 {
            guard let resource = decode(teamAndResource[0]) else {
                return nil
            }
            self.team = nil
            self.resource = resource
        } else {
            guard
                let team = decode(teamAndResource[0]),
                let resource = decode(teamAndResource[1])
                else { return nil }
            self.team = team
            self.resource = resource
        }
    }

    // MARK: - CustomStringConvertible

    var description: String {
        guard let service = encode(self.service), let resource = encode(self.resource) else {
            return ServiceIdentifier.invalidValue
        }
        if let team = self.team {
            guard let encodedTeam = encode(team) else {
                return ServiceIdentifier.invalidValue
            }
            return "\(service):\(encodedTeam)/\(resource)"
        } else {
            return "\(service):\(resource)"
        }
    }

    // MARK: - Equatable

    static func ==(lhs: ServiceIdentifier, rhs: ServiceIdentifier) -> Bool {
        return lhs.service == rhs.service && lhs.team == rhs.team && lhs.resource == rhs.resource
    }

    // MARK: - Private

    private static let invalidValue = "invalid:service"
}

extension ServiceIdentifier {
    var serviceTitle: String {
        guard
            let services = BackendClient.instance.session?.services,
            let service = services.first(where: { $0.id == self.service })
            else { return self.service }
        return service.title
    }

    var teamName: String {
        let service = BackendClient.instance.session?.services.first(where: {
            $0.id == self.service && $0.team?.id == self.team
        })
        return service?.team?.name ?? "Team"
    }
}
