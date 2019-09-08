import Foundation

struct ChunkAttachment {
    let data: DataType

    var title: String {
        // TODO: Remove the fallback after March 7, 2017.
        return (self.data["title"] as? String) ?? "untitled_file"
    }

    var url: URL {
        return URL(string: self.data["url"] as! String)!
    }

    init(data: DataType) {
        self.data = data
    }

    init(title: String, url: URL) {
        self.data = ["title": title, "url": url.absoluteString]
    }
}
