import UIKit

class AddUsersViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    @IBOutlet weak var addUsersTable: UITableView!
    @IBOutlet weak var searchField: SearchTextField!

    override func viewDidLoad() {
        super.viewDidLoad()
        self.addUsersTable.delegate = self
        self.addUsersTable.dataSource = self
        self.addUsersTable.keyboardDismissMode = .onDrag
        self.addUsersTable.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 120, right: 0)

        self.searchField.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.view.endEditing(true)
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let cell = tableView.cellForRow(at: indexPath) as! UserCell
        let user = cell.userInfo!
        let identifier = user.identifier.trimmingCharacters(in: .whitespaces)

        // TODO: Add email format check

        if let id = user.accountId {
            StreamService.instance.getOrCreateStream(participants: [Intent.Participant(accountId: id)], showInRecents: true, title: nil) { _, _ in }
        } else {
            Intent.sendInvite(identifiers: [identifier], inviteToken: nil, names: nil).perform(BackendClient.instance)
        }
        self.searchResult = nil
        self.searchField.text = nil
        if !self.addedUsers.contains(user) {
            self.addedUsers.insert(user, at: 0)
        }
        tableView.reloadSections(IndexSet(integersIn: 0...1), with: .none)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return self.searchResult == nil ? 0 : 1
        default:
            return self.addedUsers.count
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UserCell", for: indexPath) as! UserCell
        let user: UserResult
        if indexPath.section == 0 {
            user = self.searchResult!
            cell.addButton.setTitleColor(.fikaBlue, for: .normal)
            cell.addButton.setTitleWithoutAnimation(user.accountId == nil ? "Invite " : "+ Add")
            cell.addButton.isLoading = self.isSearching
        } else {
            user = self.addedUsers[indexPath.row]
            cell.addButton.setTitleColor(.lightGray, for: .normal)
            cell.addButton.setTitleWithoutAnimation(user.accountId == nil ? "Invited" : "Added")
            cell.addButton.isLoading = false
        }

        cell.userInfo = user
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 60
    }

    // MARK: - Actions

    @IBAction func addUserFieldEditingChanged(_ sender: UITextField) {
        defer {
            self.addUsersTable.reloadSections(
                IndexSet(integer: 0),
                with: self.addUsersTable.numberOfRows(inSection: 0) == 0 ? .automatic : .none
            )
        }

        self.searchTimer?.invalidate()

        // Reset search cell
        guard let text = self.searchField.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            self.searchResult = nil
            return
        }

        self.searchResult = UserResult(accountId: nil, displayName: nil, identifier: text, imageURL: nil)

        let filter = text.lowercased()
        guard filter.contains("@") else {
            return
        }

        self.isSearching = true
        self.searchTimer =
            Timer.scheduledTimer(timeInterval: 0.3,
                                 target: self,
                                 selector: #selector(AddUsersViewController.performSearch),
                                 userInfo: filter,
                                 repeats: false)
    }

    @IBAction func backTapped(_ sender: Any) {
        self.dismiss(animated: true, completion: nil)
    }

    // MARK: - Private

    private var addedUsers = [UserResult]()
    private var isSearching = false
    private var searchTimer: Timer? = nil
    private var searchResult: UserResult? = nil

    dynamic private func performSearch(timer: Timer) {
        guard let filter = timer.userInfo as? String else {
            return
        }

        Intent.getProfile(identifier: filter).perform(BackendClient.instance) { result in
            self.isSearching = false
            // Ensure we are still searching (and that there is a valid row to reload)
            guard filter == self.searchField.text?.lowercased() else {
                return
            }

            if let data = result.data,
                let id = (data["id"] as? NSNumber)?.int64Value,
                let imageURL = data["image_url"] as? String,
                let name = data["display_name"] as? String {
                self.searchResult = UserResult(
                    accountId: id,
                    displayName: (name).replacingOccurrences(of: "+", with: " "),
                    identifier: filter,
                    imageURL: URL(string: imageURL))
            }
            self.addUsersTable.reloadSections(IndexSet(integer: 0), with: .none)
        }
    }
}

// TODO: Have search result and user result objects
struct UserResult {
    var accountId: Int64?
    var displayName: String?
    var identifier: String
    var imageURL: URL?
}

extension UserResult: Equatable {
    public static func ==(lhs: UserResult, rhs: UserResult) -> Bool {
        // Compare identifers only if neither side has an accountId
        guard lhs.accountId != nil || rhs.accountId != nil else {
            return lhs.identifier == rhs.identifier
        }
        return lhs.accountId == rhs.accountId
    }
}

class UserCell: SeparatorCell {
    @IBOutlet weak var profileImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var addButton: LoaderButton!

    var userInfo: UserResult! {
        didSet {
            self.titleLabel.text = self.userInfo.displayName ?? self.userInfo.identifier
            if let url = self.userInfo.imageURL {
                self.profileImageView.af_setImage(withURL: url)
            }
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        self.addButton.loader.activityIndicatorViewStyle = .gray
    }

    override func prepareForReuse() {
        self.profileImageView.image = #imageLiteral(resourceName: "single")
        self.titleLabel.text = nil
    }
}
