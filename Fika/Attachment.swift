import AlamofireImage

class Attachment {
    var type: String {
        return self.data["type"] as! String
    }

    init(data: DataType) {
        self.data = data
    }

    private(set) var data: DataType = [:]
}
