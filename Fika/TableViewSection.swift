import UIKit

protocol Action { }

enum BasicAction : Action {
    case nothing
}

protocol Section {
    var cellReuseIdentifier: String { get }
    var count: Int { get }
    var headerTitle: String? { get }
    var rowHeight: CGFloat { get }

    func canSelect(_ row: Int) -> (Bool, Action)
    func handleLongPress(_ row: Int) -> Action
    func handleSelect(_ row: Int) -> Action
    func populateCell(_ row: Int, cell: UITableViewCell)
}

/// Default implementations of Section functionality.
extension Section {
    func canSelect(_ row: Int) -> (Bool, Action) {
        return (false, BasicAction.nothing)
    }

    func handleLongPress(_ row: Int) -> Action {
        return BasicAction.nothing
    }

    func handleSelect(_ row: Int) -> Action {
        return BasicAction.nothing
    }

    func populateCell(_ row: Int, cell: UITableViewCell) { }
}
