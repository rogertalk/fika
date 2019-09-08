import Foundation

enum Page: String {
    case streams = "Streams"
    case create = "Creation"
    case chunks = "Chunks"
    case feed = "Feed"
}

protocol Pager: class {
    var isPagingEnabled: Bool { get set }
    func pageTo(_ page: Page)
}

protocol PagerPage: class {
    var pager: Pager? { get set }
    func didPage(swiped: Bool)
}
