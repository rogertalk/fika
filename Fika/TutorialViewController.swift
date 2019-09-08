import UIKit

class TutorialViewController: UIViewController, UIScrollViewDelegate {
    
    @IBOutlet weak var scrollView: UIScrollView!
    @IBOutlet weak var pageControl: UIPageControl!

    override func viewDidLoad() {
        self.scrollView.delegate = self
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.pageControl.currentPage = Int(round(scrollView.contentOffset.x / scrollView.frame.width))
    }

    @IBAction func getStartedTapped(_ sender: Any) {
        self.dismiss(animated: true, completion: nil)
    }
}
