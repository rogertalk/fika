import AVFoundation
import CoreGraphics
import CoreVideo
import Darwin
import MessageUI

extension Array {
    mutating func shuffle() {
        if count < 2 { return }
        for i in 0..<(count - 1) {
            let j = Int(arc4random_uniform(UInt32(count - i))) + i
            guard j != i else {
                continue
            }
            swap(&self[i], &self[j])
        }
    }
}

extension AVAudioSessionRouteChangeReason: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .categoryChange:
            return "categoryChange"
        case .newDeviceAvailable:
            return "newDeviceAvailable"
        case .noSuitableRouteForCategory:
            return "noSuitableRouteForCategory"
        case .oldDeviceUnavailable:
            return "oldDeviceUnavailable"
        case .override:
            return "override"
        case .routeConfigurationChange:
            return "routeConfigurationChange"
        case .unknown:
            return "unknown"
        case .wakeFromSleep:
            return "wakeFromSleep"
        }
    }
}

extension Bundle {
    var apsEnvironment: String? {
        return self.entitlements?["aps-environment"] as? String
    }

    var embeddedMobileProvision: [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        // Find first occurrence of bytes for "<plist".
        guard let startRange = data.range(of: Data(bytes: [60, 112, 108, 105, 115, 116])) else {
            return nil
        }
        let possibleEndRange = Range<Data.Index>(uncheckedBounds: (startRange.upperBound, data.endIndex))
        // Find first occurrence of bytes for "</plist>" (after the "<plist" occurrence).
        guard let endRange = data.range(of: Data(bytes: [60, 47, 112, 108, 105, 115, 116, 62]), options: [], in: possibleEndRange) else {
            return nil
        }
        let plistData = data.subdata(in: Range<Data.Index>(uncheckedBounds: (startRange.lowerBound, endRange.upperBound)))
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) else {
            return nil
        }
        return plist as? [String: Any]
    }

    var entitlements: [String: Any]? {
        return self.embeddedMobileProvision?["Entitlements"] as? [String: Any]
    }
}

fileprivate let deviceColorSpace = CGColorSpaceCreateDeviceRGB()

extension CGContext {
    static func create(with buffer: CVPixelBuffer) -> CGContext? {
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        return CGContext(
            data: address,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: deviceColorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
    }

    static func create(size: CGSize) -> CGContext? {
        return CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: deviceColorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
    }
}

extension CGImage {
    static func create(with buffer: CVPixelBuffer) -> CGImage? {
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: address,
            size: CVPixelBufferGetDataSize(buffer),
            releaseData: { (_, _, _) in })
            else { return nil }
        return CGImage(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: deviceColorSpace,
            bitmapInfo: [CGBitmapInfo.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
    }
}

extension Data {
    var hex: String {
        let pointer = (self as NSData).bytes.bindMemory(to: UInt8.self, capacity: self.count)
        var hex = ""
        for i in 0..<self.count {
            hex += String(format: "%02x", pointer[i])
        }
        return hex
    }
}

fileprivate let calendar = Calendar.autoupdatingCurrent
fileprivate let formatter = { () -> DateFormatter in
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeZone = TimeZone.autoupdatingCurrent
    return formatter
}()

extension Date {
    var day: Int {
        return calendar.component(.day, from: self)
    }

    var hour: Int {
        return calendar.component(.hour, from: self)
    }

    var minute: Int {
        return calendar.component(.minute, from: self)
    }

    var month: Int {
        return calendar.component(.month, from: self)
    }

    var second: Int {
        return calendar.component(.second, from: self)
    }

    var year: Int {
        return calendar.component(.year, from: self)
    }

    var daysAgo: Int {
        return calendar.dateComponents([.day], from: self, to: Date()).day!
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    var timeLabel: String {
        let secondsAgo = Int(Date().timeIntervalSince(self))
        if secondsAgo < 60 {
            return "\(secondsAgo)s ago"
        } else if secondsAgo < 1200 {
            return "\(secondsAgo / 60)m ago"
        } else if calendar.isDateInToday(self) {
            return self.formatted("h:mm a")
        } else if calendar.isDateInYesterday(self) {
            return self.formatted("EEE h:mm a")
        } else if self.daysAgo < 7 {
            return self.formatted("EEE")
        } else {
            return self.formatted("MMM d")
        }
    }

    /// Accessible version of the short date format.
    var timeLabelAccessible: String {
        switch self.daysAgo {
        case 0:
            return String.localizedStringWithFormat(
                NSLocalizedString("at %@", comment: "Time status; value is a time"),
                self.formattedTime)
        case 1...6:
            return self.formatted("EEEE")
        default:
            return self.formatted("MMMM d")
        }
    }

    /// Displays short date format.
    var timeLabelShort: String {
        switch self.daysAgo {
        case 0:
            return self.formattedTime
        case 1...6:
            return self.formatted("EEE")
        default:
            return self.formatted("MMM d")
        }
    }

    /// Get a new Date adjusted for the given timezone. Note that Date does not contain timezone information so this method is NOT idempotent.
    func forTimeZone(_ name: String) -> Date? {
        guard let timeZone = TimeZone(identifier: name) else {
            return nil
        }
        let seconds = timeZone.secondsFromGMT(for: self) - TimeZone.current.secondsFromGMT(for: self)
        return Date(timeInterval: TimeInterval(seconds), since: self)
    }

    fileprivate func formatted(_ format: String) -> String {
        formatter.dateFormat = format
        return formatter.string(from: self)
    }

    /// Returns something along the lines of "7 PM".
    fileprivate func formattedHour() -> String {
        let comp = calendar.dateComponents([.hour, .minute], from: self)
        let hour = min(comp.hour! + (comp.minute! >= 30 ? 1 : 0), 23)
        let ampm = hour < 12 ? calendar.amSymbol : calendar.pmSymbol
        let hour12 = hour % 12
        return "\(hour12 > 0 ? hour12 : 12) \(ampm)"
    }
}

extension DispatchSemaphore {
    func waitOrFail() -> Bool {
        return self.wait(timeout: DispatchTime.now()) == .success
    }
}

private let base62Alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".characters

extension Integer {
    var base62: String {
        var result = ""
        var quotient = self.toIntMax()
        while quotient > 0 {
            let remainder = Int(quotient % 62)
            quotient = quotient / 62
            result.insert(base62Alphabet[base62Alphabet.index(base62Alphabet.startIndex, offsetBy: remainder)], at: result.startIndex)
        }
        return result
    }
}

extension MessageComposeResult: CustomStringConvertible {
    public var description: String {
        switch self {
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        case .sent:
            return "Sent"
        }
    }
}

extension Sequence where Iterator.Element == String {
    func localizedJoin() -> String {
        var g = self.makeIterator()
        guard let first = g.next() else {
            return ""
        }
        guard let second = g.next() else {
            return first
        }
        guard var last = g.next() else {
            return String.localizedStringWithFormat(
                NSLocalizedString("LIST_TWO", value: "%@ and %@", comment: "List; only two items"), first, second)
        }
        var middle = second
        while let piece = g.next() {
            middle = String.localizedStringWithFormat(
                NSLocalizedString("LIST_MIDDLE", value: "%@, %@", comment: "List; more than three items, middle items"), middle, last)
            last = piece
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("LIST_END", value: "%@ and %@", comment: "List; more than two items, last items"),
            String.localizedStringWithFormat(
                NSLocalizedString("LIST_START", value: "%@, %@", comment: "List; more than two items, first items"), first, middle),
            last)
    }
}

private let initialsRegex = try! NSRegularExpression(pattern: "\\b[^\\W\\d_]", options: [])

extension String {
    static func randomBase62(of length: Int) -> String {
        let range = 0..<length
        let characters = range.map({ (i: Int) -> Character in
            let value = Int(arc4random_uniform(62))
            let index = base62Alphabet.index(base62Alphabet.startIndex, offsetBy: value)
            return base62Alphabet[index]
        })
        return String(characters)
    }

    var hasLetters: Bool {
        let letters = CharacterSet.letters
        return self.rangeOfCharacter(from: letters) != nil
    }

    var hexColor: UIColor? {
        let hex = self.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt32()
        guard Scanner(string: hex).scanHexInt32(&int) else {
            return nil
        }
        let a, r, g, b: UInt32
        switch hex.characters.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    func highlightingMatches(of keyphrase: String) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: self)
        do {
            let regex = try NSRegularExpression(pattern: keyphrase, options: .caseInsensitive)
            let range = NSRange(location: 0, length: self.utf16.count)
            for match in regex.matches(in: self, options: .withTransparentBounds, range: range) {
                attributedString.addAttribute(NSBackgroundColorAttributeName, value: UIColor.yellow.withAlphaComponent(0.2), range: match.range)
            }
        } catch _ {
            NSLog("Error creating regular expression")
        }
        return attributedString
    }

    var initials: String {
        let range = NSMakeRange(0, self.characters.count)
        let matches = initialsRegex.matches(in: self, options: [], range: range)
        let nsTitle = self as NSString
        switch matches.count {
        case 0:
            return "#"
        default:
            return nsTitle.substring(with: matches[0].range).uppercased()
        }
    }

    var shortName: String {
        let words = self.characters.split(separator: " ").map(String.init)
        // Build a short name, ensuring that there's at least one word with letters.
        var shortName = ""
        for word in words {
            shortName = shortName.characters.count > 0 ? "\(shortName) \(word)" : word
            if word.hasLetters {
                break
            }
        }
        guard shortName.characters.count > 0 else {
            return ""
        }
        // Remove any comma at the end of the string.
        let index = shortName.characters.index(before: shortName.endIndex)
        if shortName[index] == "," {
            shortName = shortName.substring(to: index)
        }
        return shortName
    }
}

extension UIAlertController {
    func addCancel(handler: (() -> ())? = nil) {
        self.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in handler?() }))
    }

    func addHideAction(stream: Stream, handler: (() -> ())? = nil) {
        self.addAction(UIAlertAction(title: "Hide", style: .destructive) { _ in
            StreamService.instance.removeStreamFromRecents(stream: stream)
            Intent.hideStream(streamId: stream.id).perform(BackendClient.instance) { _ in
                StreamService.instance.removeStreamFromRecents(stream: stream)
            }
            handler?()
        })
    }

    func addLikeAction(stream: Stream, chunk: Chunk, handler: (() -> ())? = nil) {
        if let session = BackendClient.instance.session, let reaction = chunk.reactions[session.id] {
            self.addAction(UIAlertAction(title: "Remove \(reaction)", style: .default) { _ in
                StreamService.instance.setChunkReaction(chunk: chunk, reaction: nil)
                handler?()
            })
        } else {
            for reaction in ["👍", "👎"] {
                self.addAction(UIAlertAction(title: reaction, style: .default) { _ in
                    StreamService.instance.setChunkReaction(chunk: chunk, reaction: reaction)
                    handler?()
                })
            }
        }
    }

    func addOpenAttachmentActionIfApplicable(chunk: PlayableChunk) {
        guard let attachment = chunk.attachments.first else {
            return
        }
        self.addAction(UIAlertAction(title: "Open Attachment", style: .default) { _ in
            AppDelegate.setImportedDocumentURL(to: attachment.url)
        })
    }

    func addPingAction(stream: Stream, handler: (() -> ())? = nil) {
        self.addAction(UIAlertAction(title: "Ping", style: .default) { _ in
            Intent.buzz(streamId: stream.id).perform(BackendClient.instance)
            handler?()
        })
    }

    func addReplyActionIfNotSelf(stream: Stream, chunk: PlayableChunk, presenter: UIViewController) {
        guard let participant = stream.getParticipant(chunk.senderId), !participant.isCurrentUser else {
            return
        }
        self.addAction(UIAlertAction(title: "Reply to \(participant.displayName.shortName)", style: .default) { _ in
            // TODO: Show loading indicator while we perform this request.
            StreamService.instance.getOrCreateStream(participants: [Intent.Participant(accountId: participant.id)], showInRecents: true) { stream, error in
                guard let stream = stream, error == nil else {
                    return
                }
                let create = presenter.storyboard?.instantiateViewController(withIdentifier: "Creation") as! CreationViewController
                create.presetStream = stream
                presenter.present(create, animated: true)
            }
        })
    }

    func addShareAction(chunk: PlayableChunk, presenter: UIViewController, reviewer: ReviewDelegate) {
        self.addAction(UIAlertAction(title: "Share Video", style: .default) { _ in
            guard CacheService.instance.hasCached(url: chunk.url) else { return }
            let review = presenter.storyboard?.instantiateViewController(withIdentifier: "Review") as! ReviewViewController
            review.delegate = reviewer
            review.recording = Recording(
                duration: TimeInterval(chunk.duration) / 1000.0,
                fileURL: CacheService.instance.getLocalURL(chunk.url),
                transcript: Promise.resolve(chunk.textSegments ?? [])
            )
            review.attachments = chunk.attachments
            review.externalContentId = chunk.externalContentId
            review.type = .share
            presenter.present(review, animated: true)
        })
    }

    func configurePopOver(sourceView: UIView, sourceRect: CGRect) {
        guard let popover = self.popoverPresentationController else {
            return
        }
        popover.sourceView = sourceView
        popover.sourceRect = sourceRect
    }
}

extension UIButton {
    func setTitleWithoutAnimation(_ title: String) {
        UIView.performWithoutAnimation {
            self.setTitle(title, for: .normal)
            self.layoutIfNeeded()
        }
    }

    func setImageWithAnimation(_ image: UIImage?) {
        guard let imageView = self.imageView else {
            return
        }
        if let newImage = image, let oldImage = imageView.image {
            let crossFade = CABasicAnimation(keyPath: "contents")
            crossFade.duration = 0.1
            crossFade.fromValue = oldImage.cgImage
            crossFade.toValue = newImage.cgImage
            crossFade.isRemovedOnCompletion = true
            crossFade.fillMode = kCAFillModeForwards
            self.imageView?.layer.add(crossFade, forKey: "animateContents")
        }
        self.setImage(image, for: .normal)
    }
}

extension UIColor {
    static var fikaRed: UIColor {
        return "FF3A3A".hexColor!
    }

    static var fikaBlue: UIColor {
        return  "4C90F5".hexColor!
    }

    static var fikaGray: UIColor {
        return "FAFAFA".hexColor!
    }

    static var lightGray: UIColor {
        return "AAAAAA".hexColor!
    }
}

extension UIDevice {
    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8 , value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }

    var modelName: String {
        let identifier = self.modelIdentifier
        switch identifier {
        case "iPod5,1":                                  return "iPod Touch 5"
        case "iPod7,1":                                  return "iPod Touch 6"
        case "iPhone3,1", "iPhone3,2", "iPhone3,3":      return "iPhone 4"
        case "iPhone4,1":                                return "iPhone 4s"
        case "iPhone5,1", "iPhone5,2":                   return "iPhone 5"
        case "iPhone5,3", "iPhone5,4":                   return "iPhone 5c"
        case "iPhone6,1", "iPhone6,2":                   return "iPhone 5s"
        case "iPhone7,2":                                return "iPhone 6"
        case "iPhone7,1":                                return "iPhone 6 Plus"
        case "iPhone8,1":                                return "iPhone 6s"
        case "iPhone8,2":                                return "iPhone 6s Plus"
        case "iPhone8,4":                                return "iPhone SE"
        case "iPhone9,1", "iPhone9,3":                   return "iPhone 7"
        case "iPhone9,2", "iPhone9,4":                   return "iPhone 7 Plus"
        case "iPad2,1", "iPad2,2", "iPad2,3", "iPad2,4": return "iPad 2"
        case "iPad3,1", "iPad3,2", "iPad3,3":            return "iPad 3"
        case "iPad3,4", "iPad3,5", "iPad3,6":            return "iPad 4"
        case "iPad4,1", "iPad4,2", "iPad4,3":            return "iPad Air"
        case "iPad5,3", "iPad5,4":                       return "iPad Air 2"
        case "iPad2,5", "iPad2,6", "iPad2,7":            return "iPad Mini"
        case "iPad4,4", "iPad4,5", "iPad4,6":            return "iPad Mini 2"
        case "iPad4,7", "iPad4,8", "iPad4,9":            return "iPad Mini 3"
        case "iPad5,1", "iPad5,2":                       return "iPad Mini 4"
        case "iPad6,7", "iPad6,8":                       return "iPad Pro"
        case "AppleTV5,3":                               return "Apple TV"
        case "i386", "x86_64":                           return "Simulator"
        default:                                         return identifier
        }
    }
}

extension UIFont {
    class func annotationFont(ofSize size: CGFloat) -> UIFont {
        return UIFont(name: "VarelaRound-Regular", size: size)!
    }

    class func materialFont(ofSize size: CGFloat) -> UIFont {
        return UIFont(name: "MaterialIcons-Regular", size: size)!
    }
}

extension UIImage {
    func scaleToFitSize(_ size: CGSize) -> UIImage? {
        guard let image = self.cgImage else {
            return nil
        }
        // Get the largest dimension and convert it from points to pixels.
        let screenScale = UIScreen.main.nativeScale
        let major = max(size.width, size.height) * screenScale
        // Calculate new dimensions for the image so that its smallest dimension fits within the specified size.
        let originalWidth = CGFloat(image.width), originalHeight = CGFloat(image.height)
        let minor = min(originalWidth, originalHeight)
        let scale = major / minor
        let width = originalWidth * scale, height = originalHeight * scale
        // Render and return a resampled image.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: CGPoint.zero, size: CGSize(width: width, height: height)))
        return context.makeImage().flatMap { UIImage(cgImage: $0, scale: screenScale, orientation: .up) }
    }
}

extension UINavigationController {
    open override func viewDidLoad() {
        super.viewDidLoad()
        self.interactivePopGestureRecognizer?.delegate = nil
    }
}

extension UIView {
    var layoutDirection: UIUserInterfaceLayoutDirection {
        return UIView.userInterfaceLayoutDirection(for: self.semanticContentAttribute)
    }

    @IBInspectable var borderColor: UIColor? {
        get { return UIColor(cgColor: self.layer.borderColor!) }
        set { self.layer.borderColor = newValue?.cgColor }
    }

    @IBInspectable var shadowColor: UIColor? {
        get { return UIColor(cgColor: self.layer.shadowColor!) }
        set { self.layer.shadowColor = newValue?.cgColor }
    }

    func hideAnimated(callback: (() -> ())? = nil) {
        UIView.animate(withDuration: 0.15, delay: 0, options: .beginFromCurrentState, animations: {
            self.alpha = 0
        }) { success in
            if success {
                self.isHidden = true
                self.alpha = 1
            }
            callback?()
        }
    }

    func blink() {
        self.alpha = 0
        self.isHidden = false
        UIView.animate(
            withDuration: 0.7,
            delay: 0,
            options: [.autoreverse, .repeat, .curveEaseOut],
            animations: { self.alpha = 1 })
    }

    /// A quick size pulse animation for UI feedback
    func pulse(_ scale: Double = 1.3) {
        let s = CGFloat(scale)
        UIView.animate(withDuration: 0.1, delay: 0.0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            self.transform = CGAffineTransform(scaleX: s, y: s)
            }, completion: { success in
                UIView.animate(withDuration: 0.1, delay: 0.0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
                    self.transform = CGAffineTransform.identity
                    }, completion: nil)
        })
    }

    func set(shadowX x: CGFloat, y: CGFloat, radius: CGFloat, color: UIColor, opacity: Float) {
        self.layer.shadowColor = color.cgColor
        self.layer.shadowOffset = CGSize(width: x, height: y)
        self.layer.shadowOpacity = opacity
        self.layer.shadowRadius = radius
    }

    func showAnimated() {
        if self.isHidden {
            self.alpha = 0
        }
        self.isHidden = false
        UIView.animate(withDuration: 0.15, delay: 0, options: .beginFromCurrentState, animations: {
            self.alpha = 1
        }, completion: nil)
    }

    func unsetShadow() {
        self.layer.shadowColor = nil
        self.layer.shadowOffset = .zero
        self.layer.shadowOpacity = 0
        self.layer.shadowRadius = 0
    }
}

extension URL {
    /// Returns the file size of the URL in bytes, or nil if getting the file size failed. Only works for file URLs.
    var fileSize: UInt64? {
        guard
            self.isFileURL,
            let attributes = try? FileManager.default.attributesOfItem(atPath: self.path)
            else { return nil }
        return attributes[.size] as? UInt64
    }

    /// Parses a query string and returns a dictionary that contains all the key/value pairs.
    func parseQueryString() -> [String: [String]]? {
        guard let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        var data = [String: [String]]()
        for item in items {
            var list = data[item.name] ?? [String]()
            if let value = item.value {
                list.append(value)
            }
            data[item.name] = list
        }
        return data
    }

    /// Creates a random file path to a file in the temporary directory.
    static func temporaryFileURL(_ fileExtension: String) -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let randomId = ProcessInfo.processInfo.globallyUniqueString
        return temp.appendingPathComponent(randomId).appendingPathExtension(fileExtension)
    }
}
