import UIKit

protocol ServiceImportable {
    var identifier: String { get }
    var name: String { get }

    init(data: [String: Any])
}

struct ServiceGroup: ServiceImportable {
    let identifier: String
    let name: String

    init(data: [String: Any]) {
        self.identifier = data["identifier"] as! String
        self.name = data["title"] as! String
    }
}

struct ServiceUser: ServiceImportable {
    let identifier: String
    let name: String
    let timezone: String?

    var localTime: Date? {
        guard let name = self.timezone else {
            return nil
        }
        return Date().forTimeZone(name)!
    }

    init(data: [String: Any]) {
        self.identifier = data["identifier"] as! String
        self.name = data["display_name"] as! String
        self.timezone = data["timezone"] as? String
    }
}

protocol ServiceImportPickerDelegate: class {
    func serviceImport(_ picker: ServiceImportPickerViewController, didFinishPickingStream stream: Stream)
    func serviceImport(_ picker: ServiceImportPickerViewController, requestServiceReconnect serviceId: String)
}

class ServiceImportPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var importablesTable: UITableView!

    weak var delegate: ServiceImportPickerDelegate?
    var service: ConnectedService?
    var mode: ImportMode = .users

    enum ImportMode { case groups, users }

    var importables: [ServiceImportable] = [] {
        didSet {
            // Build sorted index title to importable map.
            self.importables.forEach { importable in
                guard let firstCharacter = importable.name.characters.first else {
                    return
                }
                let firstLetter = String(firstCharacter).localizedUppercase
                if self.importableIndexMap[firstLetter] == nil {
                    self.importableIndexMap[firstLetter] = [importable]
                } else {
                    self.importableIndexMap[firstLetter]!.append(importable)
                }
            }
            // Track section index titles as a sorted array
            self.indexTitles = self.importableIndexMap.keys.sorted(by: { $0 < $1 })
            self.importablesTable.reloadData()
        }
    }

    override func viewDidLoad() {
        self.importablesTable.dataSource = self
        self.importablesTable.delegate = self
        self.activityIndicator.startAnimating()

        guard let service = self.service else {
            self.importables = []
            self.activityIndicator.stopAnimating()
            return
        }

        let intent: Intent
        let serviceType: ServiceImportable.Type
        if self.mode == .groups {
            intent = Intent.getServiceGroups(service: service.id, teamId: service.team?.id)
            serviceType = ServiceGroup.self
        } else {
            intent = Intent.getServiceUsers(service: service.id, teamId: service.team?.id)
            serviceType = ServiceUser.self
        }
        intent.perform(BackendClient.instance) { result in
            self.activityIndicator.stopAnimating()
            guard let data = result.data?["data"] as? [[String: AnyObject]], result.successful else {
                let alert: UIAlertController
                switch result.code {
                case 404:
                    alert = UIAlertController(title: "Oops!", message: "Please reconnect your \(service.title) account to fika.io.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Reconnect", style: .default) { _ in
                        self.delegate?.serviceImport(self, requestServiceReconnect: service.id)
                    })
                    alert.addAction(UIAlertAction(title: "Cancel", style: .destructive) { _ in
                        self.dismiss(animated: true, completion: nil)
                    })
                default:
                    alert = UIAlertController(title: "Oops!", message: "Something went wrong. Please try again later.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in
                        self.dismiss(animated: true, completion: nil)
                    })
                }
                self.present(alert, animated: true, completion: nil)
                return
            }
            self.importables = data.map { serviceType.init(data: $0) }
            self.activityIndicator.stopAnimating()
        }
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    @IBAction func backTapped(_ sender: AnyObject) {
        self.dismiss(animated: true, completion: nil)
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return self.indexTitles.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.importableIndexMap[self.indexTitles[section]]?.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = self.importablesTable.dequeueReusableCell(withIdentifier: "ImportableCell", for: indexPath) as! ImportableCell
        cell.nameLabel.text = self.importableIndexMap[self.indexTitles[indexPath.section]]![indexPath.row].name
        return cell
    }

    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        return self.indexTitles
    }

    func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        return self.indexTitles.index(of: title)!
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath:  IndexPath) {
        let importable = self.importableIndexMap[self.indexTitles[indexPath.section]]![indexPath.row]
        self.importablesTable.allowsSelection = false
        self.activityIndicator.startAnimating()

        switch self.mode {
        case .groups:
            let identifier = ServiceIdentifier(value: importable.identifier)!
            StreamService.instance.joinStream(serviceIdentifier: identifier) { stream, error in
                self.importablesTable.allowsSelection = true
                self.activityIndicator.stopAnimating()
                guard let stream = stream, error == nil else {
                    let alert = UIAlertController(title: "Oops!", message: "Failed to import the group. Try again.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
                    self.present(alert, animated: true, completion: nil)
                    return
                }
                self.delegate?.serviceImport(self, didFinishPickingStream: stream)
            }
        case .users:
            let participant = Intent.Participant(identifiers: [(label: "backend", identifier: importable.identifier)])
            StreamService.instance.getOrCreateStream(participants: [participant], showInRecents: true) { stream, error in
                self.importablesTable.allowsSelection = true
                self.activityIndicator.stopAnimating()
                guard let stream = stream, error == nil else {
                    let alert = UIAlertController(title: "Oops!", message: "Failed to start the conversation. Try again.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
                    self.present(alert, animated: true, completion: nil)
                    return
                }
                self.delegate?.serviceImport(self, didFinishPickingStream: stream)
            }
        }
    }

    // MARK: - Private

    private var indexTitles = [String]()
    private var importableIndexMap = [String: [ServiceImportable]]()
}

class ImportableCell: SeparatorCell {
    @IBOutlet weak var nameLabel: UILabel!
}
