import UIKit

protocol ParticipantsPickerDelegate: class {
    func participantsPicker(picker: ParticipantsPickerController, didCreateStream stream: Stream)
}

class ParticipantsPickerController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    weak var delegate: ParticipantsPickerDelegate?
    var streamId: Int64?
    var streamTitle: String? {
        didSet {
            self.streamTitleLabel?.text = self.streamTitle
        }
    }

    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var doneButton: UIButton!
    @IBOutlet weak var participantsTableView: UITableView!
    @IBOutlet weak var streamTitleLabel: UILabel!

    // MARK: - UIViewController

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override func viewDidLoad() {
        self.doneButton.setTitle(self.streamId == nil ? "Create" : "Add", for: .normal)
        self.participantsTableView.dataSource = self
        self.participantsTableView.delegate = self
        self.participantsTableView.setEditing(true, animated: false)
        self.streamTitleLabel.text = self.streamTitle
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.participants.count
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Participant")! as! ParticipantOptionCell
        cell.nameLabel.text = participants[indexPath.row].displayName
        return cell
    }

    // MARK: - Actions

    @IBAction func backTapped(_ sender: Any) {
        self.dismiss(animated: true)
    }

    @IBAction func doneTapped(_ sender: Any) {
        guard
            let indexes = self.participantsTableView.indexPathsForSelectedRows?.map({ $0.row }),
            indexes.count > 0
            else
        {
            let alert: UIAlertController
            if self.streamId == nil {
                alert = UIAlertController(title: "Create empty group?",
                                          message: "Are you sure you want to create an empty group?",
                                          preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Yes", style: .default) { _ in
                    self.createOrUpdateStream(participants: [])
                })
                alert.addAction(UIAlertAction(title: "No", style: .cancel))
            } else {
                alert = UIAlertController(title: "Hold on!", message: "Pick at least one person.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Okay", style: .default))            }
            self.present(alert, animated: true)
            return
        }
        self.createOrUpdateStream(participants: indexes.map({ Intent.Participant(accountId: self.participants[$0].id) }))
    }

    // MARK: - Private

    private lazy var participants: [Participant] = { self.calculateParticipants() }()

    private func calculateParticipants() -> [Participant] {
        var participants = [Participant]()
        var seenIds = Set<Int64>()
        for s in StreamService.instance.streams.values {
            for p in s.otherParticipants {
                guard !seenIds.contains(p.id) else {
                    continue
                }
                participants.append(p)
                seenIds.insert(p.id)
            }
        }
        return participants.sorted(by: { (a, b) in a.displayName < b.displayName })
    }

    private func createOrUpdateStream(participants: [Intent.Participant]) {
        self.doneButton.isHidden = true
        self.activityIndicator.startAnimating()
        if let id = self.streamId {
            // Add to existing stream.
            StreamService.instance.addParticipants(streamId: id, participants: participants) { error in
                self.handleResult(stream: StreamService.instance.streams[id], error: error)
            }
        } else {
            // Create a new stream.
            StreamService.instance.createStream(participants: participants, title: self.streamTitle, image: nil) { stream, error in
                self.handleResult(stream: stream, error: error)
            }
        }
    }

    private func handleResult(stream: Stream?, error: Error?) {
        self.activityIndicator.stopAnimating()
        self.doneButton.isHidden = false
        guard error == nil, let stream = stream else {
            let alert = UIAlertController(title: "Uh oh!", message: "Sorry, an error occurred. Please try again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Okay", style: .default))
            self.present(alert, animated: true)
            return
        }
        self.delegate?.participantsPicker(picker: self, didCreateStream: stream)
    }
}

class ParticipantOptionCell: UITableViewCell {
    @IBOutlet weak var nameLabel: UILabel!
}
