import UIKit
import WebKit

struct MediaRequestInfo {
    let url: URL
    let frame: CGRect
    let pageTitle: String?
    let pageURL: URL?
}

protocol PresentationViewDelegate: class {
    func presentationView(_ view: PresentationView, requestingToPlay mediaURL: URL, with info: MediaRequestInfo)
}

class PresentationView: DrawableView, VisualizerDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    // TODO: Use different enum or files vs webpages if we decide on different UX
    enum Attachment {
        case none
        case document(URL)
        case image(UIImage)
        case webPage(URL)
    }

    var attachment: Attachment = .none {
        didSet {
            self.activityIndicator.stopAnimating()
            switch oldValue {
            case .none:
                break
            case .document, .webPage:
                self.webView.isHidden = true
                self.webView.load(URLRequest(url: URL(string: "about:blank")!))
            case .image:
                self.imageView.isHidden = true
                self.imageView.zoomView?.removeFromSuperview()
                if let url = BackendClient.instance.session?.imageURL {
                    self.backgroundImageView.af_setImage(withURL: url)
                } else {
                    self.backgroundImageView.image = nil
                }
            }
            switch self.attachment {
            case let .document(url):
                self.webView.loadFileURL(url, allowingReadAccessTo: url)
                self.webView.isHidden = false
            case let .image(image):
                self.imageView.isHidden = false
                self.imageView.display(image: image)
                self.backgroundImageView.image = image
            case let .webPage(url):
                self.webView.load(URLRequest(url: url))
                self.webView.isHidden = false
                self.bringSubview(toFront: self.activityIndicator)
                self.activityIndicator.startAnimating()
            case .none:
                break
            }
        }
    }

    weak var delegate: PresentationViewDelegate?

    var hasAttachment: Bool {
        if case .none = self.attachment {
            return false
        }
        return true
    }

    var isRecording = false {
        didSet {
            self.visualizer.isActive = !self.visualizer.isHidden && self.isRecording
        }
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.backgroundColor = .black

        // Set up the blurred background and audio visualizer.
        let center = CGRect(x: self.frame.width / 2, y: self.frame.height / 2, width: 0, height: 0)
        self.visualizer.frame = center.insetBy(dx: -75, dy: -75)
        self.visualizer.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin, .flexibleBottomMargin, .flexibleLeftMargin]
        self.visualizer.awakeFromNib()
        self.visualizer.isHidden = true
        self.visualizer.visualizerDelegate = self
        self.backgroundImageView.clipsToBounds = true
        self.backgroundImageView.frame = frame
        self.backgroundImageView.awakeFromNib()
        self.backgroundImageView.contentMode = .scaleAspectFill
        self.addSubview(self.backgroundImageView)
        self.addSubview(self.visualizer)

        self.activityIndicator.center = CGPoint(x: self.frame.midX, y: self.frame.midY)
        self.activityIndicator.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin, .flexibleBottomMargin, .flexibleLeftMargin]
        self.activityIndicator.hidesWhenStopped = true
        self.addSubview(self.activityIndicator)
        self.webView.backgroundColor = UIColor.black

        if let url = BackendClient.instance.session?.imageURL {
            self.visualizer.setImage(url: url)
            self.backgroundImageView.af_setImage(withURL: url)
        }
    }

    func goBack() {
        self.webView.goBack()
    }

    func hideAudioVisualizer() {
        self.visualizer.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.webView.frame = self.bounds
        self.imageView.frame = self.bounds
        self.backgroundImageView.frame = self.bounds
        self.visualizer.isActive = false
    }

    func showAudioVisualizer() {
        if let url = BackendClient.instance.session?.imageURL {
            self.visualizer.setImage(url: url)
            self.backgroundImageView.af_setImage(withURL: url)
        }
        self.visualizer.isHidden = false
        self.visualizer.isActive = self.isRecording
    }

    // MARK: - VisualizerDelegate

    var audioLevel: Float {
        let level = Recorder.instance.audioLevel
        return 1 + 0.1 * level / pow(level, 0.7)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("%@", "WARNING: Web navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.activityIndicator.stopAnimating()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let info = message.body as? [String: Any], let type = info["type"] as? String else {
            return
        }
        switch type {
        case "play":
            guard
                let src = info["src"] as? String,
                let url = URL(string: src),
                let rect = info["frame"] as? [String: CGFloat],
                let x = rect["x"], let y = rect["y"],
                let width = rect["width"], let height = rect["height"]
                else { return }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            let requestInfo = MediaRequestInfo(url: url, frame: frame, pageTitle: message.webView?.title, pageURL: message.webView?.url)
            self.delegate?.presentationView(self, requestingToPlay: url, with: requestInfo)
        default:
            print("Unhandled message type \(type)")
        }
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame?.isMainFrame != true {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: - Private

    private let backgroundImageView = BlurredImageView()

    private lazy var imageView: ImageScrollView! = {
        let view = ImageScrollView(frame: self.bounds)
        view.contentMode = .scaleAspectFit
        view.isHidden = true
        self.addSubview(view)
        return view
    }()

    private let activityIndicator = UIActivityIndicatorView(activityIndicatorStyle: .gray)
    private let panGesture = UIPanGestureRecognizer()
    private let path = UIBezierPath()
    private let tapGesture = UITapGestureRecognizer()
    private let visualizer = AvatarVisualizerView()

    private lazy var webView: WKWebView = {
        // Load a script that will hijack audio/video.
        let js = try! String(contentsOfFile: Bundle.main.path(forResource: "HijackVideo", ofType: "js")!)
        let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        // Create a controller which will receive messages from the hijack script.
        let controller = WKUserContentController()
        controller.add(self, name: "fika")
        controller.addUserScript(script)
        // Create and configure a web view used for presentations.
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let view = WKWebView(frame: self.bounds, configuration: config)
        view.isHidden = true
        view.navigationDelegate = self
        view.uiDelegate = self
        self.addSubview(view)
        return view
    }()
}
