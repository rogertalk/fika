import UIKit

class PagingViewController: UIPageViewController, Pager, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIScrollViewDelegate {

    var pages = [UIViewController]()

    override var prefersStatusBarHidden: Bool {
        // TODO: better way to show/hide the status bar
        return !self.shouldShowStatusBar
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .slide
    }

    func present(url: URL) {
        self.navigationController?.presentedViewController?.dismiss(animated: true, completion: nil)
        _ = self.navigationController?.popToRootViewController(animated: true)
        self.pageTo(.create)
        let creation = self.pages.first(where: { $0.restorationIdentifier == Page.create.rawValue }) as! CreationViewController
        creation.present(url: url)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        (self.view.subviews.first as? UIScrollView)?.delaysContentTouches = false
        self.delegate = self
        self.dataSource = self

        //self.createPage(.streams)
        let create = self.createPage(.create)
        self.createPage(.feed)

        DispatchQueue.main.async {
            self.setViewControllers([create], direction: .forward, animated: false, completion: nil)
            if let url = AppDelegate.getImportedDocumentURL() {
                self.present(url: url)
            }
        }
        self.updateStatusBar(for: create)

        VolumeMonitor.instance.active = true

        AppDelegate.userSelectedStream.addListener(self, method: PagingViewController.handleUserSelectedStream)
        AppDelegate.documentImported.addListener(self, method: PagingViewController.handleDocumentImported)
    }

    // MARK: - Pager

    var isPagingEnabled: Bool {
        get {
            return (self.view.subviews.first as? UIScrollView)?.isScrollEnabled ?? false
        }
        set {
            (self.view.subviews.first as? UIScrollView)?.isScrollEnabled = newValue
        }
    }

    func pageTo(_ page: Page) {
        guard
            let to = self.pages.index(where: { $0.restorationIdentifier == page.rawValue }),
            let currentVC = self.viewControllers?.first,
            let from = self.pages.index(of: currentVC),
            from != to
            else { return }
        let vc = self.pages[to]
        // Do not allow interaction until the paging is complete.
        self.view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            self.setViewControllers([vc], direction: from > to ? .reverse : .forward, animated: true) { _ in
                if let page = vc as? PagerPage {
                    page.didPage(swiped: false)
                }
                self.view.isUserInteractionEnabled = true
            }
        }
        self.updateStatusBar(for: vc)
    }

    // MARK: - UIPageViewControllerDelegate

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard let vc = pendingViewControllers.first else {
            return
        }
        self.updateStatusBar(for: vc)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard let vc = pageViewController.viewControllers?.first else {
            return
        }
        if completed, let page = vc as? PagerPage {
            page.didPage(swiped: true)
        }
        self.updateStatusBar(for: vc)
    }

    // MARK: - UIPageViewControllerDataSource

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let currentIndex = self.pages.index(of: viewController) else {
            return nil
        }
        return currentIndex == self.pages.count - 1 ? nil : self.pages[currentIndex + 1]
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let currentIndex = self.pages.index(of: viewController) else {
            return nil
        }
        return currentIndex > 0 ? self.pages[currentIndex - 1] : nil
    }

    // MARK: - Private

    private var shouldShowStatusBar: Bool = true
    private var isStatusBarDark: Bool = true

    @discardableResult
    private func createPage(_ page: Page) -> UIViewController {
        let vc = self.storyboard!.instantiateViewController(withIdentifier: page.rawValue)
        if let page = vc as? PagerPage {
            page.pager = self
        }
        self.pages.append(vc)
        return vc
    }

    private func updateStatusBar(for vc: UIViewController) {
        guard let identifier = vc.restorationIdentifier else {
            return
        }
        switch identifier {
        case "Streams":
            self.shouldShowStatusBar = true
            self.isStatusBarDark = false
        case "Chunks":
            self.shouldShowStatusBar = true
            self.isStatusBarDark = true
        case "Feed":
            self.shouldShowStatusBar = true
            self.isStatusBarDark = true
        default:
            self.shouldShowStatusBar = false
        }

        UIView.animate(withDuration: 0.2) {
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    private func handleDocumentImported() {
        guard let url = AppDelegate.getImportedDocumentURL() else {
            return
        }
        self.present(url: url)
    }

    private func handleUserSelectedStream(stream: Stream) {
        guard self.navigationController?.topViewController == self else {
            return
        }
        let chunks = self.storyboard?.instantiateViewController(withIdentifier: "Chunks") as! ChunksViewController
        chunks.stream = stream
        self.navigationController?.pushViewController(chunks, animated: true)
    }
}
